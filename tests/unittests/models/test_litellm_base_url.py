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

from unittest import mock

import pytest
from google.adk.models.lite_llm import LiteLlm
from google.adk.models.lite_llm import LiteLLMClient
from google.adk.models.llm_request import LlmRequest
from google.genai import types


@pytest.mark.asyncio
async def test_litellm_passes_base_url_to_acompletion():
  """LiteLlm forwards base_url to the underlying client.acompletion call."""
  test_url = "http://proxy.test/v1"

  mock_response = mock.MagicMock()
  mock_response.choices = [
      mock.MagicMock(
          message=mock.MagicMock(
              content="hello",
              role="assistant",
              tool_calls=None,
              reasoning_content=None,
          ),
          finish_reason="stop",
      )
  ]
  mock_response.model = "openai/gpt-4o"
  mock_response.usage = None

  with mock.patch.object(
      LiteLLMClient, "acompletion", new=mock.AsyncMock(return_value=mock_response)
  ) as mock_acompletion:
    llm = LiteLlm(model="openai/gpt-4o", base_url=test_url)

    request = LlmRequest(
        model="openai/gpt-4o",
        contents=[types.Content(role="user", parts=[types.Part(text="hi")])],
    )

    async for _ in llm.generate_content_async(request):
      pass

    mock_acompletion.assert_called_once()
    _, kwargs = mock_acompletion.call_args
    assert kwargs.get("base_url") == test_url
