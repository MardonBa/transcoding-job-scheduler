# Download

The user downloads a finished output. The download goes through the API so ownership can be checked, then the API answers with a 302 redirect to a short-lived presigned MinIO URL and the browser fetches the file directly from MinIO. Other users' tasks return 404 and expired outputs have no link. Reflects the Storage, Auth and Download sections of IMPLEMENTATION_NOTES.md.

```mermaid
sequenceDiagram
    actor User
    participant Browser as Next.js frontend
    participant API as Go api
    participant RStream as Redis
    participant PG as Postgres
    participant MinIO

    User->>Browser: click download
    Browser->>API: GET /api/tasks/id/download (navigation, sid cookie)
    API->>RStream: look up session (Redis)
    alt no valid session
        API-->>Browser: 401 unauthenticated
    else session valid
        API->>PG: SELECT task WHERE id AND user_id = session user
        alt not found or not owner
            API-->>Browser: 404 not_found
        else status EXPIRED
            API-->>Browser: 410 output_expired (output deleted after 24h)
        else status is not SUCCESS
            API-->>Browser: 409 output_not_ready
        else status SUCCESS
            API->>API: Sign GET with the public MinIO client (bucket outputs, key user_id/task_id.ext, 5 min, Content-Disposition attachment with name_transcoded.ext). Signing is local, no MinIO call
            API-->>Browser: 302 Location presigned URL
            Browser->>MinIO: GET presigned URL
            MinIO-->>Browser: video bytes (saved as sanitized filename)
        end
    end
```

## Notes
- The session is looked up in Redis. Video bytes never pass through the Go api. The browser fetches the file from MinIO through nginx at /outputs/..., see docs/NGINX.md.
- The frontend only renders the link while the task is SUCCESS, so the 409 and 410 cases are rare and show up as plain JSON pages.
- Outputs are kept 24h (output_expires_at). After cleanup the task is EXPIRED and the UI shows no link.
