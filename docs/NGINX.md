# nginx Reverse Proxy

nginx is the only container with a published port. It puts the frontend, the api and MinIO's bucket URLs on one origin (`http://localhost`). One origin means:
- the session cookie works everywhere,
- there's no CORS,
- `EventSource` needs no special options,
- presigned URLs point at an address the browser can actually reach.

## Routes

| Path | Upstream | Notes |
|---|---|---|
| `= /api/events` | `api:8080` | SSE: no buffering, long read timeout |
| `/api/` | `api:8080` | REST. Path passed through unchanged, because Go mounts its routes under `/api` |
| `~ ^/(uploads\|outputs)(/\|$)` | `minio:9000` | Browser uploads (presigned POST) and downloads (presigned GET). Path and Host must stay unchanged |
| `/` | `frontend:3000` | Next.js, including the dev HMR websocket |

Not routed: `/healthz`, `/readyz` and `/metrics` on the Go services, and the MinIO console. The console is published on `9001` in dev only.

The Next.js app must not define pages at `/uploads` or `/outputs`, because nginx sends those paths to MinIO.

## Config

Stored in the repo at `deploy/nginx/nginx.conf`.

```nginx
worker_processes auto;

events { worker_connections 1024; }

http {
    log_format main '$remote_addr "$request" $status $body_bytes_sent '
                    '$request_time rid=$request_id';
    access_log /dev/stdout main;
    error_log  /dev/stderr warn;

    # Needed for the Next.js dev server's HMR websocket.
    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    upstream frontend { server frontend:3000; }
    upstream api      { server api:8080;   keepalive 16; }
    upstream minio    { server minio:9000; keepalive 16; }

    server {
        listen 80;
        server_name localhost;

        client_max_body_size 1m;

        proxy_http_version 1.1;

        # proxy_set_header is NOT inherited into a location that sets any header itself,
        # so the common ones are repeated in every location below.

        # SSE. Exact match, so it wins over /api/.
        location = /api/events {
            proxy_pass http://api;
            proxy_set_header X-Real-IP       $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Request-ID    $request_id;
            proxy_set_header Host $host;
            proxy_set_header Connection "";
            proxy_buffering off;
            proxy_cache off;
            gzip off;
            proxy_read_timeout 1h;
        }

        location /api/ {
            proxy_pass http://api;
            proxy_set_header X-Real-IP       $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Request-ID    $request_id;
            proxy_set_header Host $host;
            proxy_set_header Connection "";
            proxy_read_timeout 30s;   # /uploaded runs ffprobe with a 10s timeout
        }

        # MinIO, path-style buckets. Presigned GET signatures include the Host header
        # and the path, so both have to reach MinIO exactly as the browser sent them.
        location ~ ^/(uploads|outputs)(/|$) {
            proxy_pass http://minio;            # no URI part, so the path is passed through unchanged
            proxy_set_header X-Real-IP       $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Request-ID    $request_id;
            proxy_set_header Host $http_host;   # includes the port if it isn't 80
            proxy_set_header Connection "";
            client_max_body_size 510m;          # 500 MB max file plus multipart form overhead
            proxy_request_buffering off;        # stream uploads straight to MinIO
            proxy_buffering off;                # stream downloads straight to the browser
            proxy_read_timeout 15m;
            proxy_send_timeout 15m;
        }

        location / {
            proxy_pass http://frontend;
            proxy_set_header X-Real-IP       $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Request-ID    $request_id;
            proxy_set_header Host $host;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
        }
    }
}
```

## Presigned URLs through nginx

S3 Signature V4 signs the Host header and the path of a presigned GET. The api reaches MinIO at `minio:9000`, but the browser reaches it at `localhost`, so the api uses **two MinIO clients**:

| Client | Endpoint | Used for |
|---|---|---|
| internal | `MINIO_ENDPOINT=minio:9000` | StatObject, RemoveObject, worker downloads and uploads, and the presigned GET that ffprobe reads from inside the api container |
| public | `MINIO_PUBLIC_ENDPOINT=localhost` | Only for signing the browser's presigned POST (uploads) and presigned GET (downloads) |

Settings on both clients:
- `BucketLookup: minio.BucketLookupPath`, so URLs look like `http://localhost/uploads/...`, which matches the nginx location.
- `Region: "us-east-1"`. Signing then needs no network call. Without a region, minio-go asks the endpoint for the bucket location, and inside the api container `localhost` is the api itself, so that request would fail.
- `Secure: false` in dev.

**Object keys.** The bucket name is not part of the key:

| Bucket | Key | URL the browser sees |
|---|---|---|
| `uploads` | `{user_id}/{task_id}` | `http://localhost/uploads/{user_id}/{task_id}` |
| `outputs` | `{user_id}/{task_id}.{ext}` | `http://localhost/outputs/{user_id}/{task_id}.{ext}` |

If nginx is published on another port (say 8080), then `MINIO_PUBLIC_ENDPOINT`, `APP_BASE_URL` and the Google redirect URI must all include `:8080`.

## Compose

```yaml
nginx:
  image: nginx:1.27-alpine
  ports:
    - "80:80"
  volumes:
    - ./deploy/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
  depends_on: [frontend, api, minio]
  networks: [edge]
```

- `api`, `frontend` and `minio` publish no ports.
- `minio` joins both the `edge` and `backend` networks, so nginx and the workers can both reach it.
- `minio-init` creates the `uploads` and `outputs` buckets and the lifecycle rule. Bucket policies stay private, so all access goes through signed URLs.

## How the api trusts nginx

- The client IP for per-IP rate limits comes from `X-Real-IP`. That header can only be trusted because the api's port isn't published, so every request goes through nginx.
- `X-Request-ID` from nginx becomes the request ID in logs and error bodies.
- The SSE handler also sends `X-Accel-Buffering: no`. That's redundant with `proxy_buffering off`, but it guards against config drift.

## Checklist when something breaks

| Symptom | Likely cause |
|---|---|
| Upload or download answers 403 `SignatureDoesNotMatch` | Host or path rewritten by nginx, or `MINIO_PUBLIC_ENDPOINT` doesn't match the address in the browser |
| Upload answers 413 | `client_max_body_size` on the bucket location is too small |
| Upload answers 403 with a policy error | File larger than the declared `size_bytes`, or the upload window has passed |
| SSE events arrive in bursts or only on close | Buffering is on, either `proxy_buffering` or gzip |
| SSE drops every 60s | `proxy_read_timeout` left at the default |
| Next.js hot reload doesn't work | Upgrade or Connection headers missing on `/` |
| Login loops back to the landing page | `COOKIE_SECURE=true` over plain http |

## Production (out of scope)

Terminate TLS at nginx, set `COOKIE_SECURE=true`, and switch `APP_BASE_URL`, `MINIO_PUBLIC_ENDPOINT` and the Google redirect URI to the real domain.
