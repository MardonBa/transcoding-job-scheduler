# Input Validation

Validation happens in two places in the api. Lane A validates transcode params when the job is created, before anything is uploaded. Lane B validates the actual video when the browser confirms an upload, so the user finds out right away. Any failure in lane B marks the task FAILED with an error_code. Reflects the Input Validation, Rate Limiting and Job Creation sections of IMPLEMENTATION_NOTES.md.

```mermaid
flowchart TD
    subgraph A["Lane A - POST /jobs params validation"]
        A1(["Request received"]) --> A2{"Videos per job at most 10?"}
        A2 -- no --> AR["Reject request"]
        A2 -- yes --> A3{"Queued tasks of user plus new tasks at most 50?"}
        A3 -- no --> AR
        A3 -- yes --> A4{"Container in mp4, webm, mkv?"}
        A4 -- no --> AR
        A4 -- yes --> A5{"Codec in h264, h265, vp9 and valid for container?"}
        A5 -- no --> AR
        A5 -- yes --> A6{"Resolution in 480p, 720p, 1080p, original?"}
        A6 -- no --> AR
        A6 -- yes --> A7{"Quality is CRF in range or bitrate 500k to 20M?"}
        A7 -- no --> AR
        A7 -- yes --> A8{"fps in 24, 30, 60, original?"}
        A8 -- no --> AR
        A8 -- yes --> A9{"Audio is keep or strip?"}
        A9 -- no --> AR
        A9 -- yes --> A10["Write job and tasks as PENDING_UPLOAD and return presigned PUT urls"]
    end

    subgraph B["Lane B - POST /tasks/id/uploaded confirmation"]
        B1(["Browser confirms upload"]) --> B2{"StatObject finds the object?"}
        B2 -- no --> BF
        B2 -- yes --> B3{"Real size at most 2GB?"}
        B3 -- no --> BF
        B3 -- yes --> B4["ffprobe on presigned GET url with 10s timeout"]
        B4 --> B5{"ffprobe succeeded and found a video stream?"}
        B5 -- no --> BF
        B5 -- yes --> B6{"Format in mp4, mov, mkv, webm, avi?"}
        B6 -- no --> BF
        B6 -- yes --> B7{"Duration at most 30 min?"}
        B7 -- no --> BF
        B7 -- yes --> B8{"Resolution at most 4K?"}
        B8 -- no --> BF
        B8 -- yes --> B9{"fps at most 60?"}
        B9 -- no --> BF
        B9 -- yes --> B9a{"Requested resolution above source?"}
        B9a -- yes --> B9b["Clamp resolution to original"]
        B9a -- no --> B10
        B9b --> B10["Store ffprobe output in input_metadata"]
        B10 --> B11(["Task QUEUED and job status recomputed"])
        BF(["Task FAILED with error_code and job status recomputed"])
    end

    A10 -.-> B1
```

## Notes

- Lane A rejects the whole request, so nothing is written and no upload urls are issued. Rate limits and the size and count checks belong to the same step.
- The no-upscaling rule needs the source resolution, which is only known after the upload. It is checked at upload confirmation, and a too-high resolution is clamped to original instead of failing the task.
- The size is taken from StatObject, never from the size the client sent.
- The worker re-runs ffprobe before transcoding anyway.
- Lane B failures use error_code invalid_input or unsupported_codec. upload_timeout is used by cleanup for tasks never uploaded.
