# ChatterboxCore

Shared source package for Chatterbox and Golem. App repositories consume a pinned Git submodule at `Core/`. Sources are compiled by each product with its existing compilation conditions; this is a source package, not a SwiftPM binary/module. This preserves the current conditional UI/headless architecture without changing runtime behavior.

Owns reusable chat views, engine, mobile screens, RPC/protocol, prompts and agent-computer resources. App entrypoints, product icons, daemon/service executables and the Golem rig are owned by app repositories. Changes here require updating the tested submodule revision in both consumers; neither tracks a floating branch.

Extracted byte-for-byte from shelbyklein/chatterbox commit 308c681. Historical changes remain in that repository. No user data or credentials are included. Apache-2.0; see LICENSE and NOTICE.
