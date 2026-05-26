# LuCI PortWeaver UI - TypeScript Source

This directory contains the TypeScript source code for the LuCI PortWeaver UI.

## Structure

```
src/
├── types/          # TypeScript type definitions
├── components/     # UI component modules
├── utils/          # Utility functions
└── main.ts         # Main entry point
```

## Development

This package is managed from the `luci-app-portweaver/` pnpm workspace root.
Run dependency installation once from the workspace root:

```bash
cd ..
pnpm install
```

### Local Development
```bash
pnpm --filter @portweaver/luci-ui dev
```

### Remote Development (Auto-upload to OpenWrt)

1. Copy `.env.example` to `.env` and configure SSH settings:
```bash
cp .env.example .env
```

2. Edit `.env`:
```env
SSH_HOST=192.168.1.1
SSH_PORT=22
SSH_USERNAME=root
SSH_PASSWORD=your_password
# Or use SSH key: SSH_PRIVATE_KEY_PATH=~/.ssh/id_rsa
SSH_REMOTE_PATH=/www/luci-static/resources/view/portweaver
```

3. Start remote development:
```bash
pnpm --filter @portweaver/luci-ui dev:remote
```

This will auto-compile and upload changes to your OpenWrt device.

### Build
```bash
pnpm --filter @portweaver/luci-ui build
```

## Build Output

The TypeScript code will be compiled and bundled into:
`../htdocs/luci-static/resources/view/portweaver/config.js`

This file is what gets packaged into the final IPK.

## Notes

- The src/ directory is NOT included in the IPK package
- Only the compiled output in htdocs/ is packaged
- Keep LuCI API compatibility when refactoring
