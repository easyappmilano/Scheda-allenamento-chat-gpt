import { defineConfig } from "vite";

const apiTarget = "http://127.0.0.1:54321";
const proxy = Object.fromEntries(
  ["/auth/v1", "/rest/v1", "/storage/v1", "/functions/v1", "/graphql/v1"].map((path) => [
    path,
    { target: apiTarget, changeOrigin: true, secure: false }
  ])
);
proxy["/realtime/v1"] = {
  target: "ws://127.0.0.1:54321",
  changeOrigin: true,
  ws: true
};

export default defineConfig({
  server: {
    host: "0.0.0.0",
    port: 3000,
    strictPort: true,
    allowedHosts: [".app.github.dev", "localhost"],
    proxy
  }
});
