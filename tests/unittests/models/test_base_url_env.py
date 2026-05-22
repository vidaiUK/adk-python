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
from google.adk.models.anthropic_llm import Claude
from google.adk.models.google_llm import Gemini
from google.adk.models.lite_llm import LiteLlm


def test_base_url_default_none():
  """Test that base_url is None by default when env var is not set."""
  with mock.patch.dict(os.environ, {}, clear=True):
    gemini = Gemini(model="gemini-1.5-flash")
    assert gemini.base_url is None

    claude = Claude(model="claude-3-5-sonnet-v2@20241022")
    assert claude.base_url is None

    lite = LiteLlm(model="openai/gpt-4o")
    assert lite.base_url is None


def test_explicit_base_url_overrides_env():
  """Explicit constructor value wins over any env var."""
  explicit = "http://explicit.proxy"
  with mock.patch.dict(
      os.environ,
      {
          "ADK_LLM_BASE_URL": "http://env.proxy",
          "ADK_GEMINI_BASE_URL": "http://env.gemini",
          "LITELLM_API_BASE": "http://env.litellm",
          "ANTHROPIC_BASE_URL": "http://env.anthropic",
      },
  ):
    assert Gemini(model="gemini-1.5-flash", base_url=explicit).base_url == explicit
    assert LiteLlm(model="openai/gpt-4o", base_url=explicit).base_url == explicit
    assert (
        Claude(model="claude-3-5-sonnet-v2@20241022", base_url=explicit).base_url
        == explicit
    )


def test_base_url_priority_gemini():
  """Test that provider-specific env var takes priority over global fallback."""
  global_url = "http://global.proxy"
  provider_url = "http://gemini.proxy"
  with mock.patch.dict(
      os.environ,
      {"ADK_LLM_BASE_URL": global_url, "ADK_GEMINI_BASE_URL": provider_url},
  ):
    gemini = Gemini(model="gemini-1.5-flash")
    assert gemini.base_url == provider_url


def test_base_url_priority_vertex():
  """Test that vertex-specific env var takes priority."""
  global_url = "http://global.proxy"
  vertex_url = "http://vertex.proxy"
  with mock.patch.dict(
      os.environ,
      {"ADK_LLM_BASE_URL": global_url, "ADK_VERTEX_BASE_URL": vertex_url},
  ):
    gemini = Gemini(model="gemini-1.5-flash")
    assert gemini.base_url == vertex_url


def test_base_url_priority_litellm():
  """Test that LiteLLM-specific env var takes priority."""
  global_url = "http://global.proxy"
  lite_url = "http://litellm.proxy"
  with mock.patch.dict(
      os.environ,
      {"ADK_LLM_BASE_URL": global_url, "LITELLM_API_BASE": lite_url},
  ):
    lite = LiteLlm(model="openai/gpt-4o")
    assert lite.base_url == lite_url


def test_litellm_global_fallback_appends_v1():
  """ADK_LLM_BASE_URL without a version path gets /v1 appended for LiteLlm."""
  with mock.patch.dict(
      os.environ, {"ADK_LLM_BASE_URL": "http://vidai.proxy"}, clear=True
  ):
    assert LiteLlm(model="openai/gpt-4o").base_url == "http://vidai.proxy/v1"


def test_litellm_global_fallback_strips_trailing_slash():
  """Trailing slash on ADK_LLM_BASE_URL doesn't cause double slash."""
  with mock.patch.dict(
      os.environ, {"ADK_LLM_BASE_URL": "http://vidai.proxy/"}, clear=True
  ):
    assert LiteLlm(model="openai/gpt-4o").base_url == "http://vidai.proxy/v1"


def test_litellm_global_fallback_preserves_existing_version():
  """If ADK_LLM_BASE_URL already has /v1 or /v2, don't append."""
  with mock.patch.dict(
      os.environ, {"ADK_LLM_BASE_URL": "http://vidai.proxy/v2"}, clear=True
  ):
    assert LiteLlm(model="openai/gpt-4o").base_url == "http://vidai.proxy/v2"

  with mock.patch.dict(
      os.environ, {"ADK_LLM_BASE_URL": "http://vidai.proxy/v1/extra"}, clear=True
  ):
    assert (
        LiteLlm(model="openai/gpt-4o").base_url == "http://vidai.proxy/v1/extra"
    )


def test_litellm_sdk_native_var_not_normalized():
  """LITELLM_API_BASE is pass-through — user owns the path."""
  with mock.patch.dict(
      os.environ, {"LITELLM_API_BASE": "http://custom.proxy"}, clear=True
  ):
    # No /v1 appended; user is responsible when using the SDK-native var.
    assert LiteLlm(model="openai/gpt-4o").base_url == "http://custom.proxy"


def test_gemini_and_anthropic_global_fallback_unchanged():
  """Gemini and Anthropic use ADK_LLM_BASE_URL verbatim (no /v1 suffix)."""
  with mock.patch.dict(
      os.environ, {"ADK_LLM_BASE_URL": "http://vidai.proxy"}, clear=True
  ):
    from google.adk.models.anthropic_llm import AnthropicLlm

    assert Gemini(model="gemini-1.5-flash").base_url == "http://vidai.proxy"
    assert AnthropicLlm(model="claude-3-5-sonnet").base_url == "http://vidai.proxy"
