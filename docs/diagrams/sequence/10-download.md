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
    Browser->>API: GET /tasks/id/download (session cookie)
    API->>RStream: look up session (Redis)
    alt no valid session
        API-->>Browser: 401
    else session valid
        API->>PG: SELECT task WHERE id AND user_id = session user
        alt not found or not owner
            API-->>Browser: 404
        else status EXPIRED
            API-->>Browser: 410 Gone (output deleted after 24h)
        else status is not SUCCESS
            API-->>Browser: 404
        else status SUCCESS
            API->>MinIO: presign GET outputs/user_id/task_id.ext (expires 5 min, Content-Disposition with sanitized original filename)
            MinIO-->>API: presigned URL
            API-->>Browser: 302 Location presigned URL
            Browser->>MinIO: GET presigned URL
            MinIO-->>Browser: video bytes (saved as sanitized filename)
        end
    end
```

## Notes
- The session is looked up in Redis. Video bytes never pass through the Go api.
- Outputs are kept 24h (output_expires_at). After cleanup the task is EXPIRED and the UI shows no link.
