import { spawn, type ChildProcess } from "node:child_process";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const projectRoot = resolve(__dirname, "..");

console.log("🚀 Starting development mode with auto-upload...\n");

let buildProcess: ChildProcess | null = null;
let uploadProcess: ChildProcess | null = null;

// 启动 rsbuild watch 模式
const startBuild = () => {
  console.log("📦 Starting rsbuild in watch mode...");
  buildProcess = spawn("pnpm", ["run", "build", "--watch"], {
    stdio: "inherit",
    shell: true,
    cwd: projectRoot,
  });

  buildProcess.on("error", (error) => {
    console.error("❌ Build process error:", error);
  });

  buildProcess.on("exit", (code) => {
    if (code !== 0 && code !== null) {
      console.error(`❌ Build process exited with code ${code}`);
    }
  });
};

// 启动上传监听
const startUpload = () => {
  console.log("📤 Starting upload watcher...\n");
  uploadProcess = spawn("tsx", [resolve(__dirname, "dev-upload.ts")], {
    stdio: "inherit",
    shell: true,
    cwd: projectRoot,
  });

  uploadProcess.on("error", (error) => {
    console.error("❌ Upload process error:", error);
  });

  uploadProcess.on("exit", (code) => {
    if (code !== 0 && code !== null) {
      console.error(`❌ Upload process exited with code ${code}`);
    }
  });
};

// 优雅退出
const cleanup = () => {
  console.log("\n\n👋 Shutting down...");

  if (buildProcess) {
    buildProcess.kill();
  }

  if (uploadProcess) {
    uploadProcess.kill();
  }

  process.exit(0);
};

process.on("SIGINT", cleanup);
process.on("SIGTERM", cleanup);

// 启动两个进程
startBuild();
setTimeout(startUpload, 2000); // 延迟2秒启动上传监听，确保构建先启动
