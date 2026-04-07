import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Quantneon — The Gamified Social AR/VR Hub",
  description:
    "Enter the Neon City — the gateway to the Quant Ecosystem's immersive AR/VR social hub. Powered by React Three Fiber.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className="h-full">
      <body className="h-full">{children}</body>
    </html>
  );
}

