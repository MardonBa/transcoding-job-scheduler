# Login and Account Creation

Login and account creation are one flow. The api runs the Google OIDC authorization code flow with PKCE, state and nonce, upserts the user on `google_sub`, and creates a 7 day session in Redis. The first half shows the initial `GET /api/me` check that decides between the landing page and the dashboard. No Google tokens are stored, since the app only needs to know who the user is. All traffic goes through nginx on one origin (not drawn). Reflects the Auth and UI sections of IMPLEMENTATION_NOTES.md and docs/OAUTH.md.

```mermaid
sequenceDiagram
    actor User
    participant Browser as Next.js frontend
    participant API as Go api
    participant RKV as Redis sessions/limits
    participant Google as Google OIDC
    participant PG as Postgres

    User->>Browser: Open app
    Browser->>API: GET /api/me (sid cookie if present)
    API->>RKV: GET session:{sha256(sid)}
    alt No cookie or session missing/expired
        RKV-->>API: not found
        API-->>Browser: 401 unauthenticated
        Browser-->>User: Landing page with login button
    else Valid session
        RKV-->>API: user_id
        API->>PG: SELECT user by id
        PG-->>API: user row
        API-->>Browser: 200 id, email, name, avatar_url
        Browser-->>User: Jobs dashboard
    end

    User->>Browser: Click login with Google
    Browser->>API: GET /api/auth/login?return_to=/dashboard
    Note over API: Public route, rate limited per IP
    API->>API: Validate return_to, generate state, nonce, PKCE verifier
    API->>RKV: SET oauth:{state} = nonce, verifier, return_to (10 min TTL)
    API-->>Browser: 302 to Google with state, nonce, S256 code_challenge. Set-Cookie oauth_state
    Browser->>Google: Authorize request
    Google-->>User: Sign-in and consent
    User->>Google: Sign in
    Google-->>Browser: 302 to /api/auth/callback?code&state
    Browser->>API: GET /api/auth/callback (oauth_state cookie)
    alt state does not match cookie, or GETDEL oauth:{state} finds nothing
        API-->>Browser: 302 /?auth_error=invalid_state
    else state valid
        API->>RKV: GETDEL oauth:{state}
        RKV-->>API: nonce, verifier, return_to
        API->>Google: Exchange code with code_verifier
        Google-->>API: id_token (access token discarded)
        API->>API: Verify signature via JWKS, iss, aud, exp, then nonce
        API->>PG: Upsert user on google_sub (email, name, avatar_url)
        PG-->>API: user id
        API->>RKV: DEL old session if a sid cookie was sent
        API->>RKV: SET session:{sha256(new sid)} = user_id (7 day TTL)
        API-->>Browser: 302 to return_to. Set-Cookie sid HttpOnly SameSite=Lax. Clear oauth_state
        Browser->>API: GET /api/me
        API-->>Browser: 200 user
        Browser-->>User: Jobs dashboard
    end
```

## Notes
- No Google access or refresh tokens are stored anywhere.
- Existing users get name, email and avatar refreshed by the upsert. `google_sub` is the identity key because email can change.
- The `oauth_state` cookie ties the callback to the browser that started the login, which blocks login CSRF. GETDEL makes each state single use.
- Callback failures are redirects to `/?auth_error=<code>`, never JSON, because the callback is a browser navigation.
- Logout is `POST /api/auth/logout`: delete the session key, clear the cookie, answer 204.
