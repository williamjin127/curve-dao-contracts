from vyper.interfaces import ERC20

# Voting escrow to have time-weighted votes
# The idea: votes have a weight depending on time, so that users are committed
# to the future of (whatever they are voting for).
# The weight in this implementation is linear until some max time:
# w ^
# 1 +    /-----------------
#   |   /
#   |  /
#   | /
#   |/
# 0 +----+--------------------> time
#       maxtime (2 years?)

struct Point:
    bias: int128
    slope: int128  # - dweight / dt
    ts: uint256  # timestamp

struct LockedBalance:
    amount: int128
    begin: uint256
    end: uint256


WEEK: constant(uint256) = 604800  # 7 * 86400 seconds - all future times are rounded by week
MAXTIME: constant(uint256) = 63072000  # 2 * 365 * 86400 - 2 years

token: public(address)
supply: public(uint256)

locked: public(map(address, LockedBalance))

epoch: int128
point_history: Point[100000000000000000000000000000]  # time -> unsigned point
slope_changes: public(map(uint256, int128))  # time -> signed slope change
last_checkpoint: uint256


@public
def __init__(token_addr: address):
    self.token = token_addr
    self.last_checkpoint = as_unitless_number(block.timestamp)


@private
def _checkpoint(addr: address, old_locked: LockedBalance, new_locked: LockedBalance):
    u_old: Point = Point({bias: 0, slope: 0, ts: 0})
    u_new: Point = Point({bias: 0, slope: 0, ts: 0})
    _epoch: int128 = self.epoch
    t: uint256 = as_unitless_number(block.timestamp)
    if old_locked.amount > 0 and old_locked.end > block.timestamp and old_locked.end > old_locked.begin:
        u_old.slope = old_locked.amount / convert(MAXTIME, int128)
        u_old.bias = u_old.slope * convert(old_locked.end - t, int128)
    if new_locked.amount > 0 and new_locked.end > block.timestamp and new_locked.end > new_locked.begin:
        u_new.slope = new_locked.amount / convert(MAXTIME, int128)
        u_new.bias = u_new.slope * convert(new_locked.end - t, int128)

    old_dslope: int128 = self.slope_changes[old_locked.end]
    new_dslope: int128 = 0
    if new_locked.end != old_locked.end:
        new_dslope = self.slope_changes[new_locked.end]
    else:
        new_dslope = old_dslope

    # Bias/slope (unlike change in bias/slope) is always positive
    _last_checkpoint: uint256 = self.last_checkpoint
    last_point: Point = self.point_history[_epoch]

    # Go over weeks to fill history and calculate what the current point is
    t_i: uint256 = (_last_checkpoint / WEEK) * WEEK
    for i in range(255):
        # Hopefully it won't happen that this won't get used in 5 years!
        # If it does, users will be able to withdraw but vote weight will be broken
        t_i += WEEK
        d_slope: int128 = 0
        if t_i > t:
            t_i = t
        else:
            d_slope = self.slope_changes[t_i]
        last_point.bias -= last_point.slope * convert(t_i - _last_checkpoint, int128)
        last_point.slope += d_slope
        if last_point.bias < 0:
            last_point.bias = 0
        if last_point.slope < 0:
            last_point.slope = 0
        _last_checkpoint = t_i
        last_point.ts = t_i
        _epoch += 1
        self.epoch = _epoch
        if t_i == t:
            break
        else:
            self.point_history[_epoch] = last_point

    # XXX still need to account for locking > 2 yr
    last_point.slope += (u_new.slope - u_old.slope)
    last_point.bias += (u_new.bias - u_old.bias)
    if last_point.slope < 0:
        last_point.slope = 0
    if last_point.bias < 0:
        last_point.bias = 0

    self.point_history[_epoch] = last_point

    # Slope going down is considered positive here (it actually always does, but
    # delta can have either sign
    # end comes, slope becomes smaller, so delta is negative
    # We subtract new_user_slope from [new_locked.end]
    # and add old_user_slope to [old_locked.end]
    if old_locked.end > block.timestamp:
        old_dslope += (u_old.slope - u_new.slope)
        if new_locked.end != old_locked.end:
            self.slope_changes[old_locked.end] = old_dslope

    if new_locked.end > block.timestamp:  # check in withdraw maybe?
        new_dslope -= (u_new.slope - u_old.slope)
        self.slope_changes[new_locked.end] = new_dslope


@public
@nonreentrant('lock')
def deposit(value: uint256, _unlock_time: uint256 = 0):
    # Also used to extend locktimes
    unlock_time: uint256 = (_unlock_time / WEEK) * WEEK
    _locked: LockedBalance = self.locked[msg.sender]
    old_supply: uint256 = self.supply

    if unlock_time == 0:
        assert _locked.amount > 0, "No existing stake found"
        assert _locked.end > block.timestamp, "Time to unstake"
        assert value > 0
    else:
        if _locked.amount > 0:
            assert unlock_time >= _locked.end, "Cannot make locktime smaller"
        else:
            assert value > 0
        assert unlock_time > block.timestamp, "Can only lock until time in the future"
        assert unlock_time <= as_unitless_number(block.timestamp) + MAXTIME, "Voting lock can be 2 years max"

    old_locked: LockedBalance = _locked
    if _locked.amount == 0:
        _locked.begin = as_unitless_number(block.timestamp)
    self.supply = old_supply + value
    _locked.amount += convert(value, int128)
    if unlock_time > 0:
        _locked.end = unlock_time
    self.locked[msg.sender] = _locked

    self._checkpoint(msg.sender, old_locked, _locked)

    if value > 0:
        assert_modifiable(ERC20(self.token).transferFrom(msg.sender, self, value))
    # XXX logs


@public
@nonreentrant('lock')
def withdraw(value: uint256):
    _locked: LockedBalance = self.locked[msg.sender]
    assert block.timestamp >= _locked.end
    old_supply: uint256 = self.supply

    old_locked: LockedBalance = _locked
    _locked.amount -= convert(value, int128)
    assert _locked.amount >= 0, "Withdrawing more than you have"
    self.locked[msg.sender] = _locked
    self.supply = old_supply - value

    # XXX check times
    self._checkpoint(msg.sender, old_locked, _locked)

    assert_modifiable(ERC20(self.token).transfer(msg.sender, value))
    # XXX logs


# The following ERC20/minime-compatible methods are not real balanceOf and supply!
# They measure the weights for the purpose of voting, so they don't represent
# real coins.

@public
def balanceOf(addr: address) -> uint256:
    return 0


@public
def balanceOfAt(addr: address, _block: uint256) -> uint256:
    return 0


@public
def totalSupply() -> uint256:
    return 0


@public
def totalSupplyAt(_block: uint256) -> uint256:
    return 0
