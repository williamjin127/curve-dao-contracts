from random import random, randrange
from .conftest import YEAR, approx


def test_gauge_integral(accounts, rpc, mock_lp_token, token, liquidity_gauge, gauge_controller):
    alice, bob = accounts[:2]

    # Wire up Gauge to the controller to have proper rates and stuff
    gauge_controller.add_type({'from': alice})
    gauge_controller.change_type_weight(0, 10 ** 18, {'from': alice})
    gauge_controller.add_gauge['address', 'int128', 'uint256'](
        liquidity_gauge.address, 0, 10 ** 18, {'from': alice}
    )

    alice_staked = 0
    bob_staked = 0
    integral = 0  # ∫(balance * rate(t) / totalSupply(t) dt)
    checkpoint = rpc.time()
    checkpoint_rate = token.rate()
    checkpoint_supply = 0
    checkpoint_balance = 0

    # Let Alice and Bob have about the same token amount
    mock_lp_token.transfer(bob, mock_lp_token.balanceOf(alice) // 2, {'from': alice})

    def update_integral():
        nonlocal checkpoint, checkpoint_rate, integral, checkpoint_balance, checkpoint_supply

        t1 = rpc.time()
        rate1 = token.rate()
        t_epoch = token.start_epoch_time()
        if checkpoint >= t_epoch:
            rate_x_time = (t1 - checkpoint) * rate1
        else:
            rate_x_time = (t_epoch - checkpoint) * checkpoint_rate + (t1 - t_epoch) * rate1
        if checkpoint_supply > 0:
            integral += rate_x_time * checkpoint_balance // checkpoint_supply
        checkpoint_rate = rate1
        checkpoint = t1
        checkpoint_supply = liquidity_gauge.totalSupply()
        checkpoint_balance = liquidity_gauge.balanceOf(alice)

    # Now let's have a loop where Bob always deposit or withdraws,
    # and Alice does so more rarely
    for i in range(40):
        is_alice = (random() < 0.2)
        dt = randrange(1, YEAR // 5)
        rpc.sleep(dt)

        # For Bob
        is_withdraw = (i > 0) * (random() < 0.5)
        if is_withdraw:
            amount = randrange(1, liquidity_gauge.balanceOf(bob) + 1)
            liquidity_gauge.withdraw(amount, {'from': bob})
            update_integral()
            bob_staked -= amount
        else:
            amount = randrange(1, mock_lp_token.balanceOf(bob) // 10 + 1)
            mock_lp_token.approve(liquidity_gauge.address, amount, {'from': bob})
            liquidity_gauge.deposit(amount, {'from': bob})
            update_integral()
            bob_staked += amount

        if is_alice:
            # For Alice
            is_withdraw_alice = (liquidity_gauge.balanceOf(alice) > 0) * (random() < 0.5)

            if is_withdraw_alice:
                amount_alice = randrange(1, liquidity_gauge.balanceOf(alice) // 10 + 1)
                liquidity_gauge.withdraw(amount_alice, {'from': alice})
                update_integral()
                alice_staked -= amount_alice
            else:
                amount_alice = randrange(1, mock_lp_token.balanceOf(alice) + 1)
                mock_lp_token.approve(liquidity_gauge.address, amount_alice, {'from': alice})
                liquidity_gauge.deposit(amount_alice, {'from': alice})
                update_integral()
                alice_staked += amount_alice

        assert liquidity_gauge.balanceOf(alice) == alice_staked
        assert liquidity_gauge.balanceOf(bob) == bob_staked
        assert liquidity_gauge.totalSupply() == alice_staked + bob_staked

        dt = randrange(1, YEAR // 20)
        rpc.sleep(dt)

        liquidity_gauge.user_checkpoint(alice, {'from': alice})
        update_integral()
        assert approx(liquidity_gauge.integrate_fraction(alice), integral, 1e-15)
