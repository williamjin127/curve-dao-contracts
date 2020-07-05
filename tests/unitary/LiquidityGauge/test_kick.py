import brownie

MAX_UINT256 = 2 ** 256 - 1
WEEK = 7 * 86400


def test_kick(rpc, accounts, liquidity_gauge, voting_escrow, token, mock_lp_token):
    alice, bob = accounts[:2]

    token.approve(voting_escrow, MAX_UINT256, {'from': alice})
    voting_escrow.deposit(10 ** 20, rpc.time() + WEEK, {'from': alice})

    mock_lp_token.approve(liquidity_gauge.address, MAX_UINT256, {'from': alice})
    liquidity_gauge.deposit(10 ** 21, {'from': alice})

    assert liquidity_gauge.working_balances(alice) == 10 ** 21

    rpc.sleep(WEEK // 2)

    with brownie.reverts('dev: kick not allowed'):
        liquidity_gauge.kick(alice, {'from': bob})

    rpc.sleep(WEEK)

    liquidity_gauge.kick(alice, {'from': bob})
    assert liquidity_gauge.working_balances(alice) == 4 * 10 ** 20

    with brownie.reverts('dev: kick not needed'):
        liquidity_gauge.kick(alice, {'from': bob})
