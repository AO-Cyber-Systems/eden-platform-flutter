# eden_platform_flutter

Frontend shell package for Eden apps.

It owns:

- auth/session orchestration
- company loading and selection
- server-driven navigation loading
- shared platform shell widgets

It depends on:

- `eden_platform_api_dart` for generated Connect-Dart clients and protobuf models
- `eden_ui_flutter` for UI primitives and theme

## Example

Run the local Go dev server:

```bash
just dev-go
```

Then run the package example:

```bash
cd example
flutter run --dart-define=API_BASE_URL=http://localhost:8080
```

## Notes

- Do not hand-edit generated API code in the sibling `eden-platform-api-dart` package.
- If APIs change, update the protobuf files in `eden-platform-go` and run `just generate`.
