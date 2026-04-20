/**
 * Quantneon WebSocket Hub (Socket.io)
 *
 * High-speed multiplayer hub for:
 *  - Real-time NeonPost interactions (likes, comments)
 *  - Virtual avatar presence & movement sync
 *  - Live stream viewer/host events
 *  - Virtual lobby interactions
 */

import { Server as HttpServer } from 'http';
import { Server as SocketIOServer, Socket } from 'socket.io';
import { createAdapter } from '@socket.io/redis-adapter';
import { redis } from '../config/redis';
import { logger } from '../utils/logger';
import { env } from '../config/env';
import { verifyQuantmailToken } from '../middleware/auth';
import { prisma } from '../config/database';

export interface SocketUser {
  userId: string;
  username: string;
  socketId: string;
  room?: string;
}

/**
 * Redis-backed user presence registry for multi-instance deployments.
 * Keys: `presence:user:{userId}`
 * Value: JSON-serialized SocketUser with TTL of 30 seconds (auto-expire on disconnect)
 */
class PresenceRegistry {
  private static PRESENCE_PREFIX = 'presence:user:';
  private static PRESENCE_TTL = 30; // seconds

  /**
   * Mark user as online with automatic expiry
   */
  static async setOnline(user: SocketUser): Promise<void> {
    try {
      const key = `${this.PRESENCE_PREFIX}${user.userId}`;
      await redis.setex(key, this.PRESENCE_TTL, JSON.stringify(user));
    } catch (err) {
      logger.error({ err, userId: user.userId }, 'Failed to set user presence in Redis');
    }
  }

  /**
   * Get user presence data
   */
  static async getUser(userId: string): Promise<SocketUser | null> {
    try {
      const key = `${this.PRESENCE_PREFIX}${userId}`;
      const data = await redis.get(key);
      return data ? JSON.parse(data) : null;
    } catch (err) {
      logger.error({ err, userId }, 'Failed to get user presence from Redis');
      return null;
    }
  }

  /**
   * Remove user from presence registry
   */
  static async setOffline(userId: string): Promise<void> {
    try {
      const key = `${this.PRESENCE_PREFIX}${userId}`;
      await redis.del(key);
    } catch (err) {
      logger.error({ err, userId }, 'Failed to remove user presence from Redis');
    }
  }

  /**
   * Refresh user TTL (called periodically to keep user online)
   */
  static async refreshPresence(userId: string): Promise<void> {
    try {
      const key = `${this.PRESENCE_PREFIX}${userId}`;
      await redis.expire(key, this.PRESENCE_TTL);
    } catch (err) {
      logger.error({ err, userId }, 'Failed to refresh user presence TTL');
    }
  }

  /**
   * Get all online users (for admin/monitoring purposes)
   */
  static async getAllOnline(): Promise<SocketUser[]> {
    try {
      const keys = await redis.keys(`${this.PRESENCE_PREFIX}*`);
      if (keys.length === 0) return [];

      const values = await redis.mget(...keys);
      return values
        .filter((v): v is string => v !== null)
        .map((v) => JSON.parse(v))
        .filter((u): u is SocketUser => u !== null);
    } catch (err) {
      logger.error({ err }, 'Failed to get all online users from Redis');
      return [];
    }
  }
}

export function createSocketHub(httpServer: HttpServer): SocketIOServer {
  const io = new SocketIOServer(httpServer, {
    cors: {
      origin: env.CORS_ORIGIN,
      methods: ['GET', 'POST'],
    },
    transports: ['websocket', 'polling'],
    pingInterval: 10_000,
    pingTimeout: 5_000,
  });

  // ── Redis adapter for horizontal scaling ──────────────────────────────────
  const pubClient = redis.duplicate();
  const subClient = redis.duplicate();

  Promise.all([pubClient.connect(), subClient.connect()])
    .then(() => {
      io.adapter(createAdapter(pubClient, subClient));
      logger.info('[Socket] Redis adapter attached');
    })
    .catch((err) => {
      logger.warn({ err }, '[Socket] Redis adapter unavailable — falling back to in-memory');
    });

  // ── Authentication middleware ─────────────────────────────────────────────
  io.use(async (socket, next) => {
    const token = socket.handshake.auth.token as string | undefined;
    if (!token) return next(new Error('Missing auth token'));

    try {
      const payload = verifyQuantmailToken(token);
      const user = await prisma.user.findUnique({ where: { quantmailId: payload.sub } });
      if (!user) return next(new Error('User not registered on Quantneon'));
      if (user.isBanned) return next(new Error('Account suspended'));

      (socket as Socket & { quantneonUser?: SocketUser }).quantneonUser = {
        userId: user.id,
        username: user.username,
        socketId: socket.id,
      };
      next();
    } catch (err) {
      next(new Error('Invalid token'));
    }
  });

  // ── Connection handler ────────────────────────────────────────────────────
  io.on('connection', (socket) => {
    const socketUser = (socket as Socket & { quantneonUser?: SocketUser }).quantneonUser!;

    // Set user presence in Redis
    PresenceRegistry.setOnline({ ...socketUser, socketId: socket.id });

    logger.info({ userId: socketUser.userId }, '[Socket] User connected');

    // Periodic presence refresh (every 15s to keep TTL alive)
    const presenceInterval = setInterval(() => {
      PresenceRegistry.refreshPresence(socketUser.userId);
    }, 15_000);

    // Broadcast presence
    socket.broadcast.emit('user:online', {
      userId: socketUser.userId,
      username: socketUser.username,
    });

    // ── Room / Lobby events ──────────────────────────────────────────────
    socket.on('lobby:join', (data: { roomId: string }) => {
      socket.join(`lobby:${data.roomId}`);
      socketUser.room = data.roomId;
      logger.debug({ userId: socketUser.userId, roomId: data.roomId }, '[Socket] Joined lobby');
      socket.to(`lobby:${data.roomId}`).emit('lobby:user_joined', {
        userId: socketUser.userId,
        username: socketUser.username,
      });
    });

    socket.on('lobby:leave', (data: { roomId: string }) => {
      socket.leave(`lobby:${data.roomId}`);
      socket.to(`lobby:${data.roomId}`).emit('lobby:user_left', {
        userId: socketUser.userId,
      });
    });

    // ── Avatar movement sync ─────────────────────────────────────────────
    socket.on(
      'avatar:move',
      (data: { roomId: string; x: number; y: number; z: number; r: number }) => {
        socket.to(`lobby:${data.roomId}`).emit('avatar:moved', {
          userId: socketUser.userId,
          ...data,
        });
      },
    );

    socket.on('avatar:emote', (data: { roomId: string; emote: string }) => {
      io.to(`lobby:${data.roomId}`).emit('avatar:emoted', {
        userId: socketUser.userId,
        emote: data.emote,
      });
    });

    // ── Live stream events ───────────────────────────────────────────────
    socket.on('stream:join', async (data: { streamId: string }) => {
      socket.join(`stream:${data.streamId}`);

      try {
        await prisma.liveStream.update({
          where: { id: data.streamId },
          data: { viewerCount: { increment: 1 } },
        });
      } catch (err) {
        logger.warn(
          { err, streamId: data.streamId, userId: socketUser.userId },
          'Failed to increment stream viewer count - stream may not exist'
        );
      }

      io.to(`stream:${data.streamId}`).emit('stream:viewer_joined', {
        userId: socketUser.userId,
        username: socketUser.username,
      });
    });

    socket.on('stream:leave', async (data: { streamId: string }) => {
      socket.leave(`stream:${data.streamId}`);

      try {
        await prisma.liveStream.update({
          where: { id: data.streamId },
          data: { viewerCount: { decrement: 1 } },
        });
      } catch (err) {
        logger.warn(
          { err, streamId: data.streamId, userId: socketUser.userId },
          'Failed to decrement stream viewer count - stream may not exist'
        );
      }
    });

    socket.on('stream:reaction', (data: { streamId: string; emoji: string }) => {
      io.to(`stream:${data.streamId}`).emit('stream:reaction', {
        userId: socketUser.userId,
        emoji: data.emoji,
      });
    });

    // ── NeonPost real-time interactions ──────────────────────────────────
    socket.on('post:like', (data: { postId: string }) => {
      socket.broadcast.emit('post:liked', {
        postId: data.postId,
        userId: socketUser.userId,
      });
    });

    // ── Disconnect ───────────────────────────────────────────────────────
    socket.on('disconnect', () => {
      // Clear presence refresh interval
      clearInterval(presenceInterval);

      // Remove user from Redis presence
      PresenceRegistry.setOffline(socketUser.userId);

      // Notify room members if user was in a lobby
      if (socketUser.room) {
        socket.to(`lobby:${socketUser.room}`).emit('lobby:user_left', {
          userId: socketUser.userId,
        });
      }

      logger.info({ userId: socketUser.userId }, '[Socket] User disconnected');
      socket.broadcast.emit('user:offline', { userId: socketUser.userId });
    });
  });

  logger.info('[Socket] WebSocket hub initialised');
  return io;
}

export { PresenceRegistry };
