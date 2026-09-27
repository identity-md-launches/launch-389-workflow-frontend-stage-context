import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { readFile } from "node:fs/promises";
export default defineConfig({
  plugins: [
    react(),
    {
      name: "development-deployment-manifest",
      configureServer(server) {
        server.middlewares.use(
          "/imd-deployment.json",
          async (_req, res, next) => {
            try {
              res.setHeader("Content-Type", "application/json");
              res.end(
                await readFile(
                  new URL("../dist/imd-deployment.json", import.meta.url),
                ),
              );
            } catch {
              next();
            }
          },
        );
      },
    },
  ],
  base: "./",
  build: { outDir: "../dist", emptyOutDir: true },
  server: { host: "127.0.0.1" },
});
