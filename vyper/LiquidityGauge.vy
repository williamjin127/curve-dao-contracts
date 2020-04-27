# This gauge can be used for measuring liquidity and insurance
from vyper.interfaces import ERC20

contract CRV20:
    def start_epoch_time_write() -> timestamp: modifying
    def rate() -> uint256: constant


token: public(address)
balanceOf: public(map(address, uint256))
totalSupply: public(uint256)

# The goal is to be able to calculate ∫(rate * balance / totalSupply dt) from 0 till checkpoint
# All values are kept in units of being multiplied by 1e18
epoch_checkpoints: map(int128, timestamp) # Beginning of the epoch
last_epoch: int128

# 1e18 * ∫(rate(t) / totalSupply(t) dt) from 0 till checkpoint
integrate_inv_supply: map(int128, uint256)  # bump epoch when rate() changes
integrate_checkpoint: timestamp

# 1e18 * ∫(rate(t) / totalSupply(t) dt) from (last_action) till checkpoint
integrate_inv_supply_of: map(address, uint256)
integrate_checkpoint_of: map(address, timestamp)


# ∫(balance * rate(t) / totalSupply(t) dt) from 0 till checkpoint
integrate_fraction: public(map(address, uint256))

inflation_rate: uint256

# XXX also set_weight_fraction and integrate with * (weight / sum(all_weights))


@public
def __init__(addr: address):
    self.token = addr
    self.totalSupply = 0
    self.integrate_checkpoint = block.timestamp
    self.integrate_inv_supply[0] = 0
    self.epoch_checkpoints[0] = CRV20(addr).start_epoch_time_write()
    self.last_epoch = 0
    self.inflation_rate = CRV20(addr).rate()


@private
def checkpoint(addr: address, old_value: uint256, old_supply: uint256):
    _integrate_checkpoint: timestamp = self.integrate_checkpoint
    if block.timestamp > _integrate_checkpoint:
        _token: address = self.token
        epoch: int128 = self.last_epoch
        new_epoch_time: timestamp = CRV20(_token).start_epoch_time_write()
        _integrate_inv_supply: uint256 = self.integrate_inv_supply[epoch]
        rate: uint256 = self.inflation_rate

        dt: uint256 = 0
        # Update integral of 1/supply
        if new_epoch_time > _integrate_checkpoint:
            # Handle going across epochs
            # No less than one checkpoint is expected in 1 year
            dt = as_unitless_number(new_epoch_time - _integrate_checkpoint)
            _integrate_inv_supply += 10 ** 18 * rate * dt / old_supply
            self.integrate_inv_supply[epoch] = _integrate_inv_supply
            rate = CRV20(_token).rate()
            self.inflation_rate = rate
            epoch += 1
            self.last_epoch = epoch
            self.epoch_checkpoints[epoch] = new_epoch_time
            dt = as_unitless_number(block.timestamp - new_epoch_time)
        else:
            dt = as_unitless_number(block.timestamp - _integrate_checkpoint)
        _integrate_inv_supply += 10 ** 18 * rate * dt / old_supply

        # Update user-specific integrals
        user_epoch: int128 = epoch
        user_epoch_time: timestamp = new_epoch_time
        user_checkpoint: timestamp = self.integrate_checkpoint_of[addr]
        _epoch_inv_supply: uint256 = _integrate_inv_supply
        _integrate_inv_supply_of: uint256 = self.integrate_inv_supply_of[addr]
        _integrate_fraction: uint256 = self.integrate_fraction[addr]
        for i in range(999):
            # Going no more than 999 epochs (years?) (usually much less)
            if user_checkpoint >= user_epoch_time:
                # Last cycle => we are in the epoch of the user checkpoint
                dI: uint256 = _epoch_inv_supply - _integrate_inv_supply_of
                _integrate_fraction += old_value * dI / 10 ** 18
                break
            else:
                user_epoch -= 1
                prev_epoch_inv_supply: uint256 = self.integrate_inv_supply[user_epoch]
                dI: uint256 = _epoch_inv_supply - prev_epoch_inv_supply
                _epoch_inv_supply = prev_epoch_inv_supply
                user_epoch_time = self.epoch_checkpoints[user_epoch]
                _integrate_fraction += old_value * dI / 10 ** 18

        self.integrate_inv_supply[epoch] = _integrate_inv_supply
        self.integrate_inv_supply_of[addr] = _integrate_inv_supply
        self.integrate_fraction[addr] = _integrate_fraction
        self.integrate_checkpoint_of[addr] = block.timestamp
        self.integrate_checkpoint = block.timestamp


@public
@nonreentrant('lock')
def deposit(value: uint256):
    old_value: uint256 = self.balanceOf[msg.sender]
    old_supply: uint256 = self.totalSupply

    self.checkpoint(msg.sender, old_value, old_supply)

    self.balanceOf[msg.sender] = old_value + value
    self.totalSupply = old_supply + value

    assert_modifiable(ERC20(self.token).transferFrom(msg.sender, self, value))
    # XXX logs


@public
@nonreentrant('lock')
def withdraw(value: uint256):
    old_value: uint256 = self.balanceOf[msg.sender]
    old_supply: uint256 = self.totalSupply

    self.checkpoint(msg.sender, old_value, old_supply)

    self.balanceOf[msg.sender] = old_value - value
    self.totalSupply = old_supply - value

    assert_modifiable(ERC20(self.token).transfer(msg.sender, value))
    # XXX logs
