#!/usr/bin/env bash
###############################################################################
#  build_zeno_ui.sh – one-shot Zeno-branded LobeChat builder for macOS
#  Usage:  chmod +x build_zeno_ui.sh && ./build_zeno_ui.sh
###############################################################################
set -euo pipefail

# ─── 1. Ask for backend host ────────────────────────────────────────────────
read -rp "Enter the VPS host (or IP) running your Zeno backend: " VPS_HOST
[[ -z "$VPS_HOST" ]] && { echo "❌  Host required"; exit 1; }

# ─── 2. Install homebrew deps if missing (git, pnpm, gnu-sed) ───────────────
if ! command -v brew >/dev/null; then
  echo "🍺  Installing Homebrew…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

for pkg in git pnpm gnu-sed; do
  brew list "$pkg" &>/dev/null || brew install "$pkg"
done

# ─── 3. Clone LobeChat → ~/zeno-ui (depth=1) ────────────────────────────────
UI_DIR="$HOME/zeno-ui"
if [[ -d "$UI_DIR" ]]; then
  echo "📂  Removing old $UI_DIR"
  rm -rf "$UI_DIR"
fi
echo "⬇️   Cloning LobeChat → $UI_DIR"
git clone --depth=1 https://github.com/lobehub/lobe-chat.git "$UI_DIR"

cd "$UI_DIR"

# ─── 4. Replace visible strings "LobeChat" → "Zeno"  (UI only)  ─────────────
# We patch translation JSON, page titles, README, etc. and IGNORE imports.
echo "✏️   Re-branding visible text…"
gsed -i '' -e 's/"LobeChat"/"Zeno"/g' \
           -e 's/LobeChat · Embeddable ChatGPT web client/Zeno/g' \
           $(git ls-files | grep -E 'locales|README|LICENSE|public/.*html$')

# ─── 5. Write .env.local ────────────────────────────────────────────────────
cat > .env.local <<EOF
NEXT_PUBLIC_OPENAI_API_BASE=http://${VPS_HOST}:8000
NEXT_PUBLIC_OPENAI_API_KEY=dummy
NEXT_PUBLIC_APP_TITLE=Zeno
PORT=3210
EOF
echo "✅  .env.local written"

# ─── 6. Install deps & build ───────────────────────────────────────────────
echo "📦  Installing dependencies (pnpm)…"
pnpm install --frozen-lockfile

echo "🛠   Building production bundle…"
pnpm build

# ─── 7. Launch UI  ──────────────────────────────────────────────────────────
echo -e "\n🚀  Starting Zeno UI on http://localhost:3210  (⌘-C to stop)"
pnpm start