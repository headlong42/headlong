import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { ThemeProvider } from "next-themes";
import { NuqsAdapter } from "nuqs/adapters/react-router/v7";
import { useEffect } from "react";
import {
  isRouteErrorResponse,
  Links,
  Meta,
  Outlet,
  Scripts,
  ScrollRestoration,
  useLocation,
  useNavigate,
} from "react-router";
import { Toaster } from "sonner";

import { Navbar } from "~/components/navbar";

import type { Route } from "./+types/root";
import "./app.css";

const queryClient = new QueryClient();

export function Layout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <meta charSet="utf-8" />
        <meta
          name="viewport"
          content="width=device-width, initial-scale=1, viewport-fit=cover"
        />
        <link rel="manifest" href="/manifest.webmanifest" />
        <link rel="apple-touch-icon" href="/icons/apple-touch-icon.png" />
        <meta name="apple-mobile-web-app-capable" content="yes" />
        <meta
          name="apple-mobile-web-app-status-bar-style"
          content="black-translucent"
        />
        <meta
          name="theme-color"
          media="(prefers-color-scheme: light)"
          content="#ffffff"
        />
        <meta
          name="theme-color"
          media="(prefers-color-scheme: dark)"
          content="#0a0a0a"
        />
        <Meta />
        <Links />
      </head>
      <body>
        {children}
        <ScrollRestoration />
        <Scripts />
      </body>
    </html>
  );
}

export default function App() {
  const location = useLocation();
  const navigate = useNavigate();
  // The /talk* routes are the phone-first PWA: no dash navbar, no page
  // padding — each screen owns the full viewport.
  const talkMode = location.pathname.startsWith("/talk");

  useEffect(() => {
    if ("serviceWorker" in navigator) {
      navigator.serviceWorker
        .register("/sw.js", { updateViaCache: "none" })
        .then((reg) => reg.update())
        .catch(() => {
          // Not installable (e.g. dev over http) — the app works fine without.
        });
    }
  }, []);

  // The messaging hostname lands on /talk instead of the dash. It is
  // chat.<domain> for the first persona box and <name>-chat.<domain> for
  // later ones (harris-chat.headlong.ai): Cloudflare's free certificate
  // covers one label, so a per-persona chat host cannot be chat.<name>.
  useEffect(() => {
    const label = window.location.hostname.split(".")[0];
    if (
      (label === "chat" || label.endsWith("-chat")) &&
      location.pathname === "/"
    ) {
      navigate("/talk", { replace: true });
    }
  }, [location.pathname, navigate]);

  return (
    <QueryClientProvider client={queryClient}>
      <ThemeProvider attribute="class" defaultTheme="system" enableSystem>
        <NuqsAdapter>
          <div className="min-h-screen flex flex-col">
            {!talkMode && <Navbar />}
            <main
              className={
                talkMode
                  ? "flex flex-1 min-h-0 flex-col"
                  : "flex flex-1 min-h-0 flex-col px-0 pt-4 pb-10 sm:px-4"
              }
            >
              <Outlet />
            </main>
          </div>
          <Toaster theme="system" style={{ fontFamily: "var(--font-sans)" }} />
        </NuqsAdapter>
      </ThemeProvider>
    </QueryClientProvider>
  );
}

export function ErrorBoundary({ error }: Route.ErrorBoundaryProps) {
  let message = "Oops!";
  let details = "An unexpected error occurred.";
  let stack: string | undefined;

  if (isRouteErrorResponse(error)) {
    message = error.status === 404 ? "404" : "Error";
    details =
      error.status === 404
        ? "The requested page could not be found."
        : error.statusText || details;
  } else if (import.meta.env.DEV && error && error instanceof Error) {
    details = error.message;
    stack = error.stack;
  }

  return (
    <main className="px-0 pt-4 pb-10 sm:px-4">
      <h1>{message}</h1>
      <p>{details}</p>
      {stack && (
        <pre className="w-full p-4 overflow-x-auto">
          <code>{stack}</code>
        </pre>
      )}
    </main>
  );
}
