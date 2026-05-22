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
from google.adk.models.google_llm import Gemini

@mock.patch("google.genai.Client")
def test_gemini_passes_base_url_to_client(mock_client_class):
  """Verify Gemini model passes base_url to the underlying Google GenAI Client."""
  test_url = "http://proxy.test"
  
  # Create a Gemini model with an explicit base_url
  gemini = Gemini(model="gemini-1.5-flash", base_url=test_url)
  
  # Access the api_client property, which initializes the Client
  _ = gemini.api_client
  
  # Check if the Client was instantiated with the correct http_options
  mock_client_class.assert_called_once()
  _, kwargs = mock_client_class.call_args
  
  http_options = kwargs.get("http_options")
  assert http_options is not None
  assert http_options.base_url == test_url
