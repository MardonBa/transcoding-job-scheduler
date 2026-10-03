# Login and Account Creation

Login and account creation are one flow: the api runs the Google OIDC exchange, upserts the user on `google_sub`, and creates a 7 day session in Redis. The first half shows the initial `GET /me` check that decides between the landing page and the dashboard. Note that no Google tokens are stored, since the app only needs to know who the user is. Reflects the Auth, UI, "Account Creation" and "Login" sections of IMPLEMENTATION_NOTES.md.

```mermaid
sequenceDiagram
    actor User
    participant Browser as Next.js frontend
    participant API as Go api
    participant Google as Google OIDC
    participant PG as Postgres
    participant RKV as Redis sessions/limits

    User->>Browser: Open app
    Browser->>API: GET /me (cookie if present)
    API->>RKV: Look up session id
    alt No cookie or session missing/expired
        RKV-->>API: not found
        API-->>Browser: 401
        Browser-->>User: Landing page with login button
    else Valid session
        RKV-->>API: session (user_id)
        API->>PG: SELECT user by id
        PG-->>API: user row
        API-->>Browser: 200 user profile
        Browser-->>User: Jobs dashboard
    end

    Note over User,Google: Login and create account are the same flow
    User->>Browser: Click login with Google
    Browser->>API: Start login
    API-->>Browser: Redirect to Google
    Browser->>Google: Authorize request
    Google-->>User: Google sign-in and consent
    User->>Google: Sign in
    Google-->>Browser: Redirect to callback with auth code
    Browser->>API: GET oauth callback with code
    Note over API: Unauthenticated route, rate limited per IP
    API->>Google: Exchange code for id_token
    Google-->>API: id_token
    API->>API: Verify id_token
    API->>PG: Upsert user on google_sub (name, email, avatar)
    PG-->>API: user row
    API->>RKV: Create session (random id) with 7 day TTL
    API-->>Browser: 302 to dashboard, Set-Cookie httpOnly Secure SameSite=Lax
    Browser->>API: GET /me
    API-->>Browser: 200 user profile
    Browser-->>User: Jobs dashboard
```

## Notes
- No Google access or refresh tokens are stored anywhere.
- Existing users get name, email and avatar refreshed by the upsert. `google_sub` is the identity key because email can change.
- The code to id_token exchange step is implied by the Google OIDC flow, the notes only say the api verifies the id_token.
