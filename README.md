# ChatterboxCore

Chatterbox's shared source, consumed by the app repository as a pinned Git submodule at `Core/`. Sources are compiled by each Chatterbox target with its existing compilation conditions; this is a source package, not a SwiftPM binary/module. This preserves the current conditional UI/headless architecture without changing runtime behavior.

Owns reusable chat views, engine, mobile screens, RPC/protocol and prompts. App entrypoints, product icons and daemon/service executables are owned by the app repository. Changes here require updating the tested submodule revision in the app repository; it doesn't track a floating branch.

Extracted byte-for-byte from shelbyklein/chatterbox commit 308c681. Historical changes remain in that repository. No user data or credentials are included. Apache-2.0; see LICENSE and NOTICE.
