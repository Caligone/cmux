from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_cloud_vm_terminal_startup_uses_persistent_attach_retries():
    workspace = (ROOT / "Sources" / "Workspace.swift").read_text()
    restore = (ROOT / "Sources" / "SessionRemoteWorkspaceSnapshot+Restore.swift").read_text()
    cli = (ROOT / "CLI" / "cmux.swift").read_text()

    for source in (workspace, restore, cli):
        assert 'CMUX_SSH_RECONNECT_LIMIT=\\"${CMUX_SSH_RECONNECT_LIMIT:-86400}\\"' in source
        assert (
            'CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT=\\"${CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT:-$CMUX_SSH_RECONNECT_LIMIT}\\"'
            in source
        )
        assert (
            'CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS=\\"${CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS:-$CMUX_SSH_RECONNECT_DELAY_SECONDS}\\"'
            in source
        )
        assert '\\"$cmux_freestyle_cli\\" --socket \\"$CMUX_SOCKET_PATH\\" vm ssh-attach' in source
        assert "cmux_freestyle_attach" in source


def test_cloud_vm_retry_message_does_not_show_huge_retry_denominator():
    cli = (ROOT / "CLI" / "cmux.swift").read_text()

    assert "Waiting for the local cmux web server" in cli
    assert "Waiting for the Cloud VM service" in cli
    assert "private static func retryAttemptLabel(attempt: Int, retryLimit: Int) -> String" in cli
    assert "if retryLimit >= 86_400" in cli
