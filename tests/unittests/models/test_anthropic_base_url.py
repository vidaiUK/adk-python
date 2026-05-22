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

import os
from unittest import mock

import pytest
from google.adk.models.anthropic_llm import AnthropicLlm, Claude


@mock.patch("google.adk.models.anthropic_llm.AsyncAnthropic")
def test_anthropic_llm_passes_base_url(mock_async_anthropic):
  """Verify AnthropicLlm passes base_url to SDK."""
  test_url = "http://proxy.test"
  llm = AnthropicLlm(model="claude-3-5-sonnet", base_url=test_url)
  _ = llm._anthropic_client
  mock_async_anthropic.assert_called_once_with(base_url=test_url)


@mock.patch("google.adk.models.anthropic_llm.AsyncAnthropicVertex")
def test_claude_vertex_passes_base_url(mock_async_anthropic_vertex):
  """Verify Claude (Vertex) passes base_url to SDK."""
  test_url = "http://proxy.test"
  with mock.patch.dict(
      os.environ,
      {
          "GOOGLE_CLOUD_PROJECT": "test-project",
          "GOOGLE_CLOUD_LOCATION": "test-location",
      },
  ):
    llm = Claude(model="claude-3-5-sonnet", base_url=test_url)
    _ = llm._anthropic_client
    mock_async_anthropic_vertex.assert_called_once()
    _, kwargs = mock_async_anthropic_vertex.call_args
    assert kwargs.get("base_url") == test_url
