from .conftest import block_timestamp, YEAR, time_travel


def test_gauge_controller(w3, gauge_controller, liquidity_gauge, three_gauges, token):
    admin = w3.eth.accounts[0]
    from_admin = {'from': admin}
    type_weights = [5 * 10 ** 17, 2 * 10 ** 18]
    gauge_weights = [2 * 10 ** 18, 10 ** 18, 5 * 10 ** 17]

    # Set up gauges and types
    gauge_controller.functions.add_type().transact(from_admin)  # 0
    gauge_controller.functions.add_type().transact(from_admin)  # 1
    gauge_controller.functions.change_type_weight(0, type_weights[0]).transact(from_admin)

    gauge_controller.functions.add_gauge(three_gauges[0].address, 0).transact(from_admin)
    gauge_controller.functions.add_gauge(three_gauges[1].address, 0, gauge_weights[1]).transact(from_admin)
    gauge_controller.functions.add_gauge(three_gauges[2].address, 1, gauge_weights[2]).transact(from_admin)

    gauge_controller.functions.change_type_weight(1, type_weights[1]).transact(from_admin)

    gauge_controller.functions.change_gauge_weight(three_gauges[0].address, gauge_weights[0]).transact(from_admin)

    last_change = block_timestamp(w3)
    epoch_time = token.caller.start_epoch_time()
    assert last_change == gauge_controller.caller.last_change()
    assert gauge_controller.caller.start_epoch_time() == epoch_time

    # Check static parameters
    assert gauge_controller.caller.n_gauge_types() == 2
    assert gauge_controller.caller.n_gauges() == 3
    for i in range(3):
        assert three_gauges[i].address == gauge_controller.caller.gauges(i)
    assert gauge_controller.caller.gauge_types(three_gauges[0].address) == 0
    assert gauge_controller.caller.gauge_types(three_gauges[1].address) == 0
    assert gauge_controller.caller.gauge_types(three_gauges[2].address) == 1
    for i in range(3):
        assert gauge_controller.caller.gauge_weights(three_gauges[i].address) == gauge_weights[i]
    for i in range(2):
        assert gauge_controller.caller.type_weights(i) == type_weights[i]

    # Check incremental calculations
    sums = [sum(gauge_weights[:2]), gauge_weights[2]]
    assert gauge_controller.caller.weight_sums_per_type(0) == sums[0]
    assert gauge_controller.caller.weight_sums_per_type(1) == sums[1]
    total_weight = sum(s * t for s, t in zip(sums, type_weights))
    assert gauge_controller.caller.total_weight() == total_weight
    for i, t in [(0, 0), (1, 0), (2, 1)]:
        assert gauge_controller.caller.gauge_relative_weight(three_gauges[i].address) ==\
            10 ** 18 * type_weights[t] * gauge_weights[i] // total_weight

    # Go across 1 year and see what happens
    time_travel(w3, YEAR + YEAR // 10)
    gauge_controller.functions.last_change_write().transact(from_admin)
    assert gauge_controller.caller.start_epoch_time() == epoch_time + YEAR
    assert gauge_controller.caller.last_change() == last_change
