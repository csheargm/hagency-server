#[test]
fn both_puppet_forms_pass_the_namespace_guard_and_lookalikes_do_not() {
    let m = super::MatrixClient::new("http://127.0.0.1:1/".parse().unwrap(), "t".into(), "example.test".into()).unwrap();
    for ok in ["@_hagency_agt_01m7k5g5n36gcamvq8f8m07e6n:example.test", "@_hagency_csheargm_anna-claude-2:example.test"] {
        assert!(m.puppet(ok).is_ok(), "{ok}");
    }
    for bad in ["@alice:example.test", "@_hagency_x.y:example.test", "@_hagency_Anna:example.test", "@_hagency_a_b:other.test"] {
        assert!(m.puppet(bad).is_err(), "{bad}");
    }
}
