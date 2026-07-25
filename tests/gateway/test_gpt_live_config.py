"""GPT-Live config parsing and precedence tests."""

import yaml

from gateway.config import GPTLiveConfig, GatewayConfig, load_gateway_config


def test_gpt_live_defaults_from_dict():
    config = GPTLiveConfig.from_dict({})

    assert config.enabled is False
    assert config.model == "gpt-live-1-codex"
    assert config.protocol_version == "v3"
    assert config.voice == "sol"
    assert config.mode == "full_duplex"
    assert config.codex_binary == ""
    assert config.devicecheck_addon == ""
    assert config.start_timeout_seconds == 45
    assert config.tool_timeout_seconds == 30
    assert config.approval_timeout_seconds == 120
    assert config.reconnect_window_seconds == 120
    assert config.cooldown_default_seconds == 300
    assert config.cooldown_max_seconds == 3600
    assert config.max_call_minutes == 30
    assert config.max_concurrent_tools == 1
    assert config.command_queue_limit == 32
    assert config.notification_queue_limit == 512
    assert config.max_request_bytes == 1_048_576
    assert config.max_sdp_bytes == 524_288
    assert config.max_tool_arguments_bytes == 262_144
    assert config.max_tool_result_bytes == 65_536
    assert config.live_tool_allowlist == []


def test_gpt_live_from_dict_overrides_and_type_cleanup():
    config = GPTLiveConfig.from_dict(
        {
            "enabled": True,
            "model": "gpt-live-1-extra",
            "protocol_version": "v2",
            "mode": "half_duplex",
            "codex_binary": "/opt/gpt-live/bin/codex",
            "devicecheck_addon": "",
            "live_tool_allowlist": ["tool.send", "tool.echo", 123],
        }
    )

    assert config.enabled is True
    assert config.model == "gpt-live-1-extra"
    assert config.protocol_version == "v2"
    assert config.mode == "half_duplex"
    assert config.codex_binary == "/opt/gpt-live/bin/codex"
    assert config.devicecheck_addon == ""
    assert config.live_tool_allowlist == ["tool.send", "tool.echo"]


def test_gpt_live_from_dict_invalid_enums_paths_and_types():
    config = GPTLiveConfig.from_dict(
        {
            "protocol_version": "bogus",
            "voice": 12,
            "mode": "turbo",
            "codex_binary": "relative/path/codex",
            "devicecheck_addon": 123,
            "live_tool_allowlist": ["tool.send", 4, None],
        }
    )

    assert config.protocol_version == "v3"
    assert config.mode == "full_duplex"
    assert config.voice == "sol"
    assert config.codex_binary == ""
    assert config.devicecheck_addon == ""
    assert config.live_tool_allowlist == ["tool.send"]


def test_gpt_live_from_dict_enforces_numeric_bounds():
    config = GPTLiveConfig.from_dict(
        {
            "start_timeout_seconds": 0,
            "tool_timeout_seconds": 999,
            "approval_timeout_seconds": -1,
            "reconnect_window_seconds": -5,
            "cooldown_default_seconds": 99999,
            "cooldown_max_seconds": -100,
            "max_call_minutes": 0,
            "max_concurrent_tools": 9999,
            "command_queue_limit": 0,
            "notification_queue_limit": 1_000_000,
            "max_request_bytes": 10,
            "max_sdp_bytes": 10,
            "max_tool_arguments_bytes": 1,
            "max_tool_result_bytes": 1,
        }
    )

    assert config.start_timeout_seconds == 45
    assert config.tool_timeout_seconds == 30
    assert config.approval_timeout_seconds == 120
    assert config.reconnect_window_seconds == 120
    assert config.cooldown_default_seconds == 300
    assert config.cooldown_max_seconds == 3600
    assert config.max_call_minutes == 30
    assert config.max_concurrent_tools == 1
    assert config.command_queue_limit == 32
    assert config.notification_queue_limit == 512
    assert config.max_request_bytes == 1_048_576
    assert config.max_sdp_bytes == 524_288
    assert config.max_tool_arguments_bytes == 262_144
    assert config.max_tool_result_bytes == 65_536


def test_gpt_live_unknown_key_is_ignored():
    config = GPTLiveConfig.from_dict(
        {
            "enabled": True,
            "unexpected": "value",
            "another": {"nested": "value"},
        }
    )

    assert config.enabled is True
    assert config.model == "gpt-live-1-codex"


def test_gateway_config_loads_top_level_gpt_live_before_nested_gateway_block(tmp_path, monkeypatch):
    hermes_home = tmp_path / ".hermes"
    hermes_home.mkdir()
    config_path = hermes_home / "config.yaml"
    config_path.write_text(
        yaml.safe_dump(
            {
                "gpt_live": {
                    "enabled": True,
                    "protocol_version": "v3",
                },
                "gateway": {
                    "gpt_live": {
                        "enabled": False,
                        "protocol_version": "v2",
                        "start_timeout_seconds": 60,
                    }
                },
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setenv("HERMES_HOME", str(hermes_home))

    config = load_gateway_config()

    assert config.gpt_live.enabled is True
    assert config.gpt_live.protocol_version == "v3"
    assert config.gpt_live.start_timeout_seconds == 45


def test_gateway_config_falls_back_to_gateway_nested_gpt_live(tmp_path, monkeypatch):
    hermes_home = tmp_path / ".hermes"
    hermes_home.mkdir()
    config_path = hermes_home / "config.yaml"
    config_path.write_text(
        yaml.safe_dump(
            {
                "gateway": {
                    "gpt_live": {
                        "enabled": True,
                        "protocol_version": "v2",
                        "start_timeout_seconds": 60,
                    }
                }
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setenv("HERMES_HOME", str(hermes_home))

    config = load_gateway_config()

    assert config.gpt_live.enabled is True
    assert config.gpt_live.protocol_version == "v2"
    assert config.gpt_live.start_timeout_seconds == 60
