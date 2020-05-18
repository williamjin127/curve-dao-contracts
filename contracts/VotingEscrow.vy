from vyper.interfaces import ERC20

# Voting escrow to have time-weighted votes
# The idea: votes have a weight depending on time, so that users are committed
# to the future of (whatever they are voting for).
# The weight in this implementation is linear, and lock cannot be more than maxtime:
# w ^
# 1 +        /
#   |      /
#   |    /
#   |  /
#   |/
# 0 +--------+------> time
#       maxtime (4 years?)

struct Point:
    bias: int128
    slope: int128  # - dweight / dt
    ts: uint256
    blk: uint256  # block
# We cannot really do block numbers per se b/c slope is per time, not per block
# and per block could be fairly bad b/c Ethereum changes blocktimes.
# What we can do is to extrapolate ***At functions

struct LockedBalance:
    amount: int128
    begin: uint256
    end: uint256


WEEK: constant(uint256) = 604800  # 7 * 86400 seconds - all future times are rounded by week
MAXTIME: constant(uint256) = 126144000  # 4 * 365 * 86400 - 4 years

token: public(address)
supply: public(uint256)

locked: public(map(address, LockedBalance))

epoch: int128
point_history: Point[100000000000000000000000000000]  # epoch -> unsigned point
user_point_history: public(map(address, Point[1000000000]))  # user -> Point[user_epoch]
user_point_epoch: public(map(address, int128))
slope_changes: public(map(uint256, int128))  # time -> signed slope change


@public
def __init__(token_addr: address):
    self.token = token_addr
    self.point_history[0] = Point({
        bias: 0, slope: 0,
        blk: block.number, ts: as_unitless_number(block.timestamp)})


@private
def _checkpoint(addr: address, old_locked: LockedBalance, new_locked: LockedBalance):
    # XXX is everything ok if both checkpoints are in the same block?
    u_old: Point = Point({bias: 0, slope: 0, ts: 0, blk: 0})
    u_new: Point = Point({bias: 0, slope: 0, ts: 0, blk: 0})
    _epoch: int128 = self.epoch
    t: uint256 = as_unitless_number(block.timestamp)
    if old_locked.amount > 0 and old_locked.end > block.timestamp and old_locked.end > old_locked.begin:
        u_old.slope = old_locked.amount / convert(MAXTIME, int128)
        u_old.bias = u_old.slope * convert(old_locked.end - t, int128)
    if new_locked.amount > 0 and new_locked.end > block.timestamp and new_locked.end > new_locked.begin:
        u_new.slope = new_locked.amount / convert(MAXTIME, int128)
        u_new.bias = u_new.slope * convert(new_locked.end - t, int128)

    # Handle total slope in the rest of the method

    old_dslope: int128 = self.slope_changes[old_locked.end]
    new_dslope: int128 = 0
    if new_locked.end != old_locked.end:
        new_dslope = self.slope_changes[new_locked.end]
    else:
        new_dslope = old_dslope

    # Bias/slope (unlike change in bias/slope) is always positive
    last_point: Point = self.point_history[_epoch]
    last_checkpoint: uint256 = last_point.ts
    # For extrapolation to calculate block number (approximately, for *At methods)
    initial_last_point: Point = last_point
    block_slope: uint256 = 0
    if t > last_point.ts:
        block_slope = 10 ** 18 * (block.number - last_point.blk) / (t - last_point.ts)

    # Go over weeks to fill history and calculate what the current point is
    t_i: uint256 = (last_checkpoint / WEEK) * WEEK
    for i in range(255):
        # Hopefully it won't happen that this won't get used in 5 years!
        # If it does, users will be able to withdraw but vote weight will be broken
        t_i += WEEK
        d_slope: int128 = 0
        if t_i > t:
            t_i = t
        else:
            d_slope = self.slope_changes[t_i]
        last_point.bias -= last_point.slope * convert(t_i - last_checkpoint, int128)
        last_point.slope += d_slope
        if last_point.bias < 0:
            last_point.bias = 0
        if last_point.slope < 0:
            last_point.slope = 0
        last_checkpoint = t_i
        last_point.ts = t_i
        last_point.blk = initial_last_point.blk + block_slope * (t_i - initial_last_point.ts) / 10 ** 18
        _epoch += 1
        self.epoch = _epoch
        if t_i == t:
            last_point.blk = block.number
            break
        else:
            self.point_history[_epoch] = last_point

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

    # Now handle user history
    user_epoch: int128 = self.user_point_epoch[addr]
    user_epoch += 1
    self.user_point_epoch[addr] = user_epoch
    u_new.ts = as_unitless_number(block.timestamp)
    u_new.blk = block.number
    self.user_point_history[addr][user_epoch] = u_new


@public
@nonreentrant('lock')
def deposit(value: uint256, _unlock_time: uint256 = 0):
    """
    Deposit `value` or extend locktime
    """
    unlock_time: uint256 = (_unlock_time / WEEK) * WEEK  # Locktime is rounded down to weeks
    _locked: LockedBalance = self.locked[msg.sender]  # How much is locked previously and for how long

    if unlock_time == 0:
        # Checks needed if we are not extending the lock
        # It means that a workable lock should already exist
        assert _locked.amount > 0, "No existing lock found"
        assert _locked.end > block.timestamp, "Cannot add to expired lock. Withdraw"
        assert value > 0  # Why add zero to existing lock

    else:
        # Lock is extended, or a new one is created, with deposit added or not
        assert unlock_time >= _locked.end, "Cannot decrease the lock duration"
        if (unlock_time == _locked.end) or (_locked.end <= block.timestamp):
            # If lock is not extended, we must be adding more to it
            assert value > 0
        assert unlock_time > block.timestamp, "Can only lock until time in the future"
        assert unlock_time <= as_unitless_number(block.timestamp) + MAXTIME, "Voting lock can be 4 years max"

    self.supply += value
    old_locked: LockedBalance = _locked
    if _locked.amount == 0:
        _locked.begin = as_unitless_number(block.timestamp)
    # Adding to existing lock, or if a lock is expired - creating a new one
    _locked.amount += convert(value, int128)
    if unlock_time > 0:
        _locked.end = unlock_time
    self.locked[msg.sender] = _locked

    # Possibilities:
    # Both old_locked.end could be current or expired (>/< block.timestamp)
    # value == 0 (extend lock) or value > 0 (add to lock or extend lock)
    # _locked.end > block.timestamp (always)
    # _locked.begin = block.timestamp
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
@constant
def balanceOf(addr: address) -> uint256:
    _epoch: int128 = self.user_point_epoch[addr]
    if _epoch == 0:
        return 0
    else:
        last_point: Point = self.user_point_history[addr][_epoch]
        last_point.bias -= last_point.slope * convert(as_unitless_number(block.timestamp) - last_point.ts, int128)
        if last_point.bias < 0:
            last_point.bias = 0
        return convert(last_point.bias, uint256)


@public
@constant
def balanceOfAt(addr: address, _block: uint256) -> uint256:
    # Copying and pasting totalSupply code because Vyper cannot pass by
    # reference yet
    assert _block <= block.number
    _epoch: int128 = self.user_point_epoch[addr]
    # Binary search
    _min: int128 = 0
    _max: int128 = _epoch
    for i in range(128):  # Will be always enough for 128-bit numbers
        if _min >= _max:
            break
        _mid: int128 = (_min + _max + 1) / 2
        if self.user_point_history[addr][_mid].blk <= _block:
            _min = _mid
        else:
            _max = _mid - 1

    point: Point = self.user_point_history[addr][_min]
    dt: uint256 = 0
    if _min < _epoch:
        point_next: Point = self.user_point_history[addr][_min + 1]
        if point.blk != point_next.blk:
            dt = (_block - point.blk) * (point_next.ts - point.ts) / (point_next.blk - point.blk)
    else:
        if point.blk != block.number:
            dt = (_block - point.blk) * (as_unitless_number(block.timestamp) - point.ts) / (block.number - point.blk)

    point.bias -= point.slope * convert(dt, int128)
    if point.bias >= 0:
        return convert(point.bias, uint256)
    else:
        return 0


@public
@constant
def totalSupply() -> uint256:
    last_point: Point = self.point_history[self.epoch]
    last_point.bias -= last_point.slope * convert(as_unitless_number(block.timestamp) - last_point.ts, int128)
    if last_point.bias < 0:
        last_point.bias = 0
    return convert(last_point.bias, uint256)


@public
@constant
def totalSupplyAt(_block: uint256) -> uint256:
    assert _block <= block.number
    _epoch: int128 = self.epoch
    # Binary search
    _min: int128 = 0
    _max: int128 = _epoch
    for i in range(128):  # Will be always enough for 128-bit numbers
        if _min >= _max:
            break
        _mid: int128 = (_min + _max + 1) / 2
        if self.point_history[_mid].blk <= _block:
            _min = _mid
        else:
            _max = _mid - 1

    point: Point = self.point_history[_min]
    dt: uint256 = 0
    if _min < _epoch:
        point_next: Point = self.point_history[_min + 1]
        if point.blk != point_next.blk:
            dt = (_block - point.blk) * (point_next.ts - point.ts) / (point_next.blk - point.blk)
    else:
        if point.blk != block.number:
            dt = (_block - point.blk) * (as_unitless_number(block.timestamp) - point.ts) / (block.number - point.blk)

    point.bias -= point.slope * convert(dt, int128)
    if point.bias >= 0:
        return convert(point.bias, uint256)
    else:
        return 0
