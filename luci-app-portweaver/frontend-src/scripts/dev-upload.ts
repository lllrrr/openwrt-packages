import { Client, type ConnectConfig } from "ssh2";
import { watch } from "chokidar";
import { readFileSync, existsSync } from "node:fs";
import { resolve, join, dirname } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const projectRoot = resolve(__dirname, "..");

// 加载环境变量
const loadEnv = () => {
  const envPath = resolve(projectRoot, ".env");
  if (!existsSync(envPath)) {
    console.error(
      "❌ .env file not found. Please copy .env.example to .env and configure it.",
    );
    process.exit(1);
  }

  const envContent = readFileSync(envPath, "utf-8");
  const env: Record<string, string> = {};

  envContent.split("\n").forEach((line) => {
    const trimmed = line.trim();
    if (trimmed && !trimmed.startsWith("#")) {
      const [key, ...valueParts] = trimmed.split("=");
      if (key && valueParts.length > 0) {
        env[key.trim()] = valueParts.join("=").trim();
      }
    }
  });

  return env;
};

const env = loadEnv();

// SSH配置
const getSSHConfig = (): ConnectConfig => {
  const config: ConnectConfig = {
    host: env.SSH_HOST,
    port: parseInt(env.SSH_PORT || "22", 10),
    username: env.SSH_USERNAME,
  };

  // 优先使用私钥认证
  if (env.SSH_PRIVATE_KEY_PATH) {
    let keyPath = env.SSH_PRIVATE_KEY_PATH;
    // 处理 ~ 路径
    if (keyPath.startsWith("~")) {
      keyPath = join(homedir(), keyPath.slice(1));
    }

    if (existsSync(keyPath)) {
      config.privateKey = readFileSync(keyPath);
      if (env.SSH_PASSPHRASE) {
        config.passphrase = env.SSH_PASSPHRASE;
      }
      console.log("🔑 Using SSH private key authentication");
    } else {
      console.warn(
        `⚠️  Private key not found at ${keyPath}, falling back to password`,
      );
    }
  }

  // 如果没有私钥，使用密码
  if (!config.privateKey && env.SSH_PASSWORD) {
    config.password = env.SSH_PASSWORD;
    console.log("🔑 Using SSH password authentication");
  }

  if (!config.privateKey && !config.password) {
    console.error(
      "❌ No authentication method configured. Please set SSH_PASSWORD or SSH_PRIVATE_KEY_PATH in .env",
    );
    process.exit(1);
  }

  return config;
};

// 上传文件到SSH服务器
const uploadFile = async (
  localPath: string,
  remotePath: string,
): Promise<void> => {
  return new Promise((resolve, reject) => {
    const conn = new Client();

    conn.on("ready", () => {
      console.log("📡 SSH connection established");

      conn.sftp((err, sftp) => {
        if (err) {
          conn.end();
          return reject(err);
        }

        const fileContent = readFileSync(localPath);

        sftp.writeFile(remotePath, fileContent, (err) => {
          if (err) {
            conn.end();
            return reject(err);
          }

          console.log(`✅ Uploaded: ${localPath} -> ${remotePath}`);
          conn.end();
          resolve();
        });
      });
    });

    conn.on("error", (err) => {
      reject(err);
    });

    conn.connect(getSSHConfig());
  });
};

// 主函数
const main = async () => {
  console.log("🚀 Starting development mode with auto-upload...\n");

  const localDistPath = resolve(
    projectRoot,
    env.LOCAL_DIST_PATH || "../htdocs/luci-static/resources/view/portweaver",
  );
  const remotePath = env.SSH_REMOTE_PATH;

  if (!remotePath) {
    console.error("❌ SSH_REMOTE_PATH not configured in .env");
    process.exit(1);
  }

  console.log(`📂 Watching: ${localDistPath}`);
  console.log(
    `📤 Upload to: ${env.SSH_USERNAME}@${env.SSH_HOST}:${remotePath}\n`,
  );

  // 监听文件变化
  const watcher = watch(localDistPath, {
    persistent: true,
    ignoreInitial: false,
    awaitWriteFinish: {
      stabilityThreshold: 500,
      pollInterval: 100,
    },
  });

  const uploadQueue: Set<string> = new Set();
  let uploadTimer: NodeJS.Timeout | null = null;

  const processUploadQueue = async () => {
    if (uploadQueue.size === 0) return;

    const files = Array.from(uploadQueue);
    uploadQueue.clear();

    for (const file of files) {
      try {
        const fileName = file.split(/[\\/]/).pop() || "";
        const remoteFilePath = `${remotePath}/${fileName}`;
        await uploadFile(file, remoteFilePath);
      } catch (error) {
        console.error(`❌ Upload failed for ${file}:`, error);
      }
    }
  };

  watcher.on("add", (path) => {
    if (path.endsWith(".js")) {
      console.log(`📝 File added: ${path}`);
      uploadQueue.add(path);

      if (uploadTimer) clearTimeout(uploadTimer);
      uploadTimer = setTimeout(processUploadQueue, 1000);
    }
  });

  watcher.on("change", (path) => {
    if (path.endsWith(".js")) {
      console.log(`📝 File changed: ${path}`);
      uploadQueue.add(path);

      if (uploadTimer) clearTimeout(uploadTimer);
      uploadTimer = setTimeout(processUploadQueue, 1000);
    }
  });

  watcher.on("error", (error) => {
    console.error("❌ Watcher error:", error);
  });

  console.log("👀 Watching for changes... (Press Ctrl+C to stop)\n");

  // 优雅退出
  process.on("SIGINT", () => {
    console.log("\n\n👋 Stopping watcher...");
    watcher.close();
    process.exit(0);
  });
};

main().catch((error) => {
  console.error("❌ Fatal error:", error);
  process.exit(1);
});
