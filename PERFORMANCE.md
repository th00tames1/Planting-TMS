# Resource audit

The app records locally. Its only HTTP client is the Android GitHub updater. Automatic update checks are off by default; enabling them permits one check per day while the study is stopped. There are no ads, analytics, cloud sync, map tiles, transcription requests or remote fonts in the capture app. OS-assisted location and other phone services can independently use a network.

| Area | Budget and behavior |
| --- | --- |
| Display | Dark by default; optional light screen. Numeric updates capped around 60 per second. Android requests a 60 Hz window. Only live numeric groups repaint; static history and labels do not rebuild each frame. Hidden, covered and stopped views stop their ticker. No wake lock or forced maximum brightness. |
| Timing | Continuous monotonic clock anchors; view frames never determine elapsed time. Boundary writes are not throttled. |
| Motion | Native hardware step counter / Core Motion, without raw accelerometer streaming. Android batches sensor events for up to 5 seconds; optional aggregate persistence is throttled to 5 seconds and UI delivery to 1 second. Critical transitions save immediately. |
| Location | Automatic permission flow and bounded idle preparation. Active Android GPS requests every 5 seconds. The duplicate network-provider stream has been removed. Available fix time, age and accuracy remain explicit. Location may be a substantial part of field power consumption. |
| Audio | One mono AAC encoder at 16 kHz / 32 kbit/s, active only during Delay. Encoded data goes directly to a private file. No waveform polling or PCM buffers in Flutter. Completed files are closed and Android syncs them to storage. A still-open note can be incomplete if the process is killed. |
| Capture memory | At most 20 recent journal events and 12 compact lap summaries. Completed activity totals have four entries. No growing in-memory list of the whole study. |
| Records | 50 records per page. Native readers seek backwards through the open CSV. Browser readers now seek by sequence keys instead of repeatedly advancing from the start. |
| CSV | Native write acknowledgements follow flush. Raw current-schema rows now stream without repeated JSON/base64/checksum conversion. Earlier formats retain their originals and are projected when exported. Native buffers are bounded; browser preview exports have a 32 MB cap. |
| Updates | No updater service or polling timer. APK download and hashing use 64 KiB buffers; metadata is bounded. Size, SHA-256, package, version and signing certificate are checked. Installation requires Android approval and stopped timing. |
| Reset | Streams a replacement journal, commits an active-file manifest, then cleans retired originals. It filters only the confirmed current study. Browser deletion/resequencing is one IndexedDB transaction. Audio cleanup remains retryable after a partial cleanup failure. |

## Verification and limits

Regression coverage includes boundary milliseconds, overlapping Delay, failed-save retry, process recovery, bounded record paging, legacy CSV compatibility, current-study Reset/reopen, permissions, hidden-view ticks, 120 Hz frame limiting and installer gating during a running study. Actual recording and APK installation require a physical Android device; iOS compilation requires macOS/Xcode.

No full-day battery percentage, production RAM ceiling or physical distance accuracy is claimed. The connected phone is currently unavailable. The next field qualification should compare identical workloads at controlled brightness, with GPS and Delay audio workloads recorded separately, and check resident memory over a full shift. Startup deliberately validates native CSV history instead of skipping integrity checks; extremely large journals still need device startup timing measurements. On OLED, dark theme can reduce display power; on LCD the benefit is smaller and brightness remains important.
