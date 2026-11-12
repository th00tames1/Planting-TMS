# Export generation benchmark

The benchmark generates realistic records lazily in pages of at most 200 rows.
Each lap contains raw integer timing, decimal minutes, nullable walking data,
two custom values, and study metadata. One lap in five has an annotation and an
audit entry. No fixture list is materialized. Each command runs in a fresh Dart
process on Windows; `ProcessInfo.maxRss` measures the entire process, including
the VM and JIT startup. These are not Android, iOS, or document-provider memory
measurements, and the output-size caps are not RAM limits.

Run from `field_app`:

```
dart run test/export_benchmark.dart build 10000 csv
dart run test/export_benchmark.dart build 10000 xlsx
dart run test/export_benchmark.dart build 30000 csv
dart run test/export_benchmark.dart build 30000 xlsx
dart run test/export_benchmark.dart stream 10000 csv
dart run test/export_benchmark.dart stream 10000 xlsx
dart run test/export_benchmark.dart stream 30000 csv
dart run test/export_benchmark.dart stream 30000 xlsx
```

The original in-memory `build()` path remains available, so the comparison is
repeatable. `stream` writes through awaited `RandomAccessFile.writeFrom` calls
to a temporary file and removes it afterward. An optional fourth argument keeps
the generated file at that path for independent inspection.

Observed first-run results on 2026-10-15, in MiB (1,048,576 bytes):

| Laps | Format | Original peak RSS | Stream peak RSS | Stream file | Outcome |
|---:|---|---:|---:|---:|---|
| 10,000 | CSV | 229.1 | 194.0 | 9.0 | Both completed |
| 10,000 | XLSX | 292.6 | 204.7 | 27.7 | Both completed |
| 30,000 | CSV | 262.9 | 204.7 | 27.1 | Both completed |
| 30,000 | XLSX | 239.1 | 215.0 | 84.0 | Original hit its 32 MiB output cap; stream completed |

Raw timings, starting and ending RSS, peak RSS, byte sizes, and errors are in
`export_benchmark_before.json` and `export_benchmark_after.json`. The failed
30,000-lap original XLSX case did less work; its RSS is not a completed-export
comparison. Runtime and memory results vary between fresh processes.

The mobile UI uses `prepare().writeTo()` through `NativeExportFileSaver`:

- Database reads request at most 200 laps or audit entries per page.
- A reusable 64 KiB Dart buffer is flushed only after the native append returns.
- STORE ZIP entries use data descriptors; only the small central directory is
  retained. No complete worksheet or workbook is assembled in the native path.
- Native app-private files are limited to 512 MiB, with at most 1,000,000 laps
  and 1,000,000 audit entries. Append checks preserve a 64 MiB free-space reserve;
  actual IO failures are still caught and cleaned up.
- Android copies the file to the user-chosen URI with a 64 KiB buffer. iOS gives
  its system document picker a file URL. The operating system and chosen file
  provider may use additional buffers; their memory behavior is not guaranteed.
- Cancel preparation, generation failure, append failure, picker cancellation,
  and completion attempt immediate private-file cleanup. Abandoned private
  export files are removed when the native bridge starts on the next launch.
- The browser and fake-saver compatibility path keep the original in-memory
  32 MiB output cap. No spreadsheet library or persistent export worker is added.

Independent file check (Python with openpyxl):

```
dart run test/export_benchmark.dart stream 30000 xlsx /path/to/study.xlsx
python test/export_validate_xlsx.py /path/to/study.xlsx 30000 6000
```

The independent validator checks ZIP CRCs, parses every XML part, and reads the
workbook with openpyxl. The 30,000-lap file passed: 45,000,000 milliseconds,
750.000 decimal minutes, 2,727 unavailable distance cells, and 6,000 annotation
history rows. Pixel and iOS peak-memory measurements remain separate work.
