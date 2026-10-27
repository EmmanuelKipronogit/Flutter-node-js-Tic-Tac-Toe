# Multiplayer Tic-Tac-Toe (Flutter + Node + Postgres + Socket.IO + Gmail 2FA)

## 1. Postgres
Local (needs Docker):   docker compose up -d
Or use any hosted Postgres (Neon, Supabase, Render) and put its URL in DATABASE_URL (set PGSSL=true).
Tables are created automatically on server start (backend/schema.sql).

## 2. Gmail sender (for the 6-digit codes)
1. Google Account -> Security -> turn ON 2-Step Verification.
2. Google Account -> Security -> App passwords -> create one.
3. Put the 16 characters in backend/.env as GMAIL_APP_PASSWORD (spaces are fine) and your address in GMAIL_USER.
4. RESTART the server after editing .env. Watch the console: "Gmail SMTP ready" = working.

### "Couldn't send verification code" checklist
- Console says "Gmail SMTP failed: Invalid login"  -> wrong/old app password, 2-Step Verification off, or GMAIL_USER isn't the account that made the app password.
- Console says "Gmail SMTP failed: ETIMEDOUT/ECONNREFUSED" -> network blocks port 465; set SMTP_PORT=587.
- No Gmail message at all -> .env isn't in backend/ (or is named .env.txt), or server wasn't restarted.
- Just want to keep developing: DEV_FALLBACK=true prints the code in the server console.

## 3. Backend
cd backend && cp .env.example .env   # edit it
npm install && npm start             # http://localhost:3000

## 4. Flutter app
cd flutter_app && flutter create . && flutter pub get && flutter run -d chrome
Run a second window/emulator to play against yourself.
Android dev: add android:usesCleartextTraffic="true" to <application> in AndroidManifest.xml.
Real phone: set Api.base in lib/main.dart to your LAN IP or deployed HTTPS URL.

## Multiplayer section
- Players online counter, live list of open public games (one-tap join)
- Quick match, public rooms, private rooms with share codes
- Global chat, leaderboard, rematch, forfeit-on-leave
