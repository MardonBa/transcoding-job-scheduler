# OAuth and Sessions

Login uses Google OIDC with the authorization code flow plus PKCE, state and nonce. The Go api is the OAuth client. Logging in and creating an account are the same flow, because the user row is upserted on `google_sub`. Sequence diagram: [01-login](diagrams/sequence/01-login.md).

## Libraries

- `golang.org/x/oauth2`: auth URL, code exchange, and PKCE (`GenerateVerifier`, `S256ChallengeOption`, `VerifierOption`).
- `github.com/coreos/go-oidc/v3/oidc`: discovery, JWKS caching and id_token verification.

## Google Cloud setup

1. Create an OAuth client of type **Web application** in Google Cloud Console (APIs & Services, then Credentials).
2. Authorized redirect URI: `http://localhost/api/auth/callback`. Google allows plain http only for localhost. For a real deployment, add the https URL.
3. Set up the OAuth consent screen with scopes `openid`, `email` and `profile`. While its status is "Testing", only the listed test users can log in, which is fine for this project.

## Configuration

| Env var | Example | Notes |
|---|---|---|
| `GOOGLE_CLIENT_ID` | `123….apps.googleusercontent.com` | |
| `GOOGLE_CLIENT_SECRET` | | Secret. Keep it in `.env`, which is git-ignored |
| `APP_BASE_URL` | `http://localhost` | Used for redirects and the `Origin` check |
| `OAUTH_REDIRECT_URL` | `http://localhost/api/auth/callback` | Must match the URI registered with Google exactly |
| `SESSION_TTL` | `168h` | 7 days |
| `COOKIE_SECURE` | `false` in dev, `true` anywhere with TLS | Safari won't store `Secure` cookies over http, even on localhost |

## Flow

### 1. `GET /api/auth/login?return_to=/jobs/0192…`

1. Validate `return_to`. It must start with `/`, must not start with `//` or `/\`, and must not contain a scheme. Anything else falls back to `/dashboard`.
2. Generate:
   - `state`: 32 random bytes, base64url.
   - `nonce`: 32 random bytes, base64url.
   - `code_verifier`: from `oauth2.GenerateVerifier()`.
3. Store `oauth:{state}` in Redis as `{ "nonce", "code_verifier", "return_to" }` with a 10 min TTL.
4. Set cookie `oauth_state={state}` with `HttpOnly; SameSite=Lax; Path=/api/auth; Max-Age=600` (plus `Secure` per `COOKIE_SECURE`). This ties the flow to the browser that started it and blocks login CSRF, where an attacker gets a victim logged into the attacker's account.
5. 302 to Google's auth URL with `scope=openid email profile`, `state`, `nonce`, `code_challenge` (S256) and `prompt=select_account`.

### 2. `GET /api/auth/callback?code=…&state=…`

1. If Google sent `error` (for example the user clicked cancel), redirect to `/?auth_error=access_denied`.
2. The `state` query parameter must equal the `oauth_state` cookie. Otherwise redirect with `invalid_state`.
3. `GETDEL oauth:{state}`. If it is missing (expired or already used), redirect with `invalid_state`. Using `GETDEL` means each state works only once.
4. Clear the `oauth_state` cookie.
5. Exchange `code` with the `code_verifier`. Any failure redirects with `login_failed`.
6. Verify the `id_token` with go-oidc's verifier. It checks the signature against Google's JWKS, `iss` (`https://accounts.google.com`), `aud` (our client ID) and `exp`. Then check `id_token.Nonce` against the stored nonce yourself.
7. Read the claims `sub`, `email`, `name` and `picture`. Use only `sub` as the identity.
8. Upsert the user:
   ```sql
   INSERT INTO users (id, google_sub, email, name, avatar_url)
   VALUES ($1, $2, $3, $4, $5)
   ON CONFLICT (google_sub) DO UPDATE
     SET email = EXCLUDED.email, name = EXCLUDED.name,
         avatar_url = EXCLUDED.avatar_url, updated_at = now()
   RETURNING id;
   ```
9. If the request already carries a `sid` cookie, delete that session. Then create a new one (see below). A fresh session ID on every login prevents session fixation.
10. 302 to `return_to`.

Google's access and refresh tokens are thrown away. The app never calls Google APIs.

### Callback error codes

The callback is a browser navigation, so errors are redirects to `/?auth_error=<code>`, which the landing page shows as a message. They are never JSON.

| code | Cause |
|---|---|
| `access_denied` | The user canceled at Google |
| `invalid_state` | State missing, expired, reused, or not matching the cookie |
| `login_failed` | Code exchange or id_token verification failed |
| `rate_limited` | Per-IP limit on `/api/auth/*` |

## Sessions

- **ID.** 32 random bytes from `crypto/rand`, base64url encoded. This value is the cookie.
- **Storage.** Redis key `session:{sha256(id)}` holding `{ "user_id", "created_at" }`, with `EX` set to `SESSION_TTL`. Only the hash is stored, so a Redis dump contains no usable cookies.
- **Expiry.** Fixed 7 days from login. The TTL is not extended on use, which keeps things simple. The user logs in again weekly.
- **Cookie.** `sid={id}; HttpOnly; SameSite=Lax; Path=/; Max-Age=604800` plus `Secure` per `COOKIE_SECURE`.
- **Middleware.** Read `sid`, hash it, `GET session:{hash}`. If it is missing, answer 401 `unauthenticated`. If found, put `user_id` in the request context. The users table is not read on every request. Only `/api/me` loads the row.
- **Logout** (`POST /api/auth/logout`). `DEL session:{hash}`, clear the cookie with `Max-Age=0`, and answer 204. Open SSE streams notice on their next keepalive and close.

## CSRF

- `SameSite=Lax` means the browser doesn't send `sid` on cross-site `POST`s.
- As a second layer, the api rejects any `POST` whose `Origin` header doesn't equal `APP_BASE_URL` (403 `forbidden_origin`).
- The only state-changing `GET`s are the two `/api/auth/*` routes, and those are protected by state and the `oauth_state` cookie.

## Not in scope

No Google token storage, no refresh tokens, no "log out of all devices", no account deletion and no profile page.
