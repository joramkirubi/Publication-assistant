from src.graph import build_graph


def test_graph_compiles():
    app = build_graph()
    assert app is not None


def test_graph_has_all_four_agent_nodes():
    app = build_graph()
    node_names = set(app.get_graph().nodes.keys())
    for expected in ["repo_analyzer", "metadata_recommender", "content_improver", "reviewer_critic"]:
        assert expected in node_names
