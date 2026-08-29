import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "قِرش — لوحة الإدارة",
  description: "لوحة إدارة قِرش — المستخدمون، النمو، الكتالوج، وإعدادات النظام.",
  icons: { icon: "/brand/qirsh-coin.png" },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="ar" dir="rtl">
      <body>{children}</body>
    </html>
  );
}
