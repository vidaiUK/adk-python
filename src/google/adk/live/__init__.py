# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# --- fork-local workaround for upstream commit 85b52f6a3.
# That commit rewrote src/google/adk/agents/live_request_queue.py into a
# backwards-compatibility shim that re-exports from `google.adk.live.
# live_request_queue`, but the commit diff FAILED TO ADD the new
# `src/google/adk/live/` package. Result: `from ..live.live_request_queue
# import LiveRequestQueue` raises ModuleNotFoundError, taking down every
# test that imports `InvocationContext`.
#
# Until upstream fixes their commit and ships the missing package, we
# provide it here with the pre-refactor content, restored from
# `85b52f6a3~1:src/google/adk/agents/live_request_queue.py`. When
# upstream ships their `live/` package properly, our merge will bring
# it in (with content conflicts we resolve by taking theirs); at that
# point this fork-local file can be deleted along with this note.
