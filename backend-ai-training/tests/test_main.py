from backend_ai_training.main import main


def test_main_runs(capsys):
    main()
    captured = capsys.readouterr()
    assert "Hello from backend-ai-training!" in captured.out
