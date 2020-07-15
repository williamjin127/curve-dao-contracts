# The contract which controls gauges and issuance of coins through those

# 7 * 86400 seconds - all future times are rounded by week
WEEK: constant(uint256) = 604800

# Cannot change weight votes more often than once in 10 days
WEIGHT_VOTE_DELAY: constant(uint256) = 10 * 86400


struct Point:
    bias: uint256
    slope: uint256

struct VotedSlope:
    slope: uint256
    power: uint256
    end: uint256


interface VotingEscrow:
    def get_last_user_slope(addr: address) -> int128: view
    def locked__end(addr: address) -> uint256: view


event CommitOwnership:
    admin: address

event ApplyOwnership:
    admin: address

event NewTypeWeight:
    type_id: int128
    time: uint256
    weight: uint256
    total_weight: uint256

event NewGaugeWeight:
    gauge_address: address
    time: uint256
    weight: uint256
    total_weight: uint256

event VoteForGauge:
    time: uint256
    user: address
    gauge_addr: address
    weight: uint256


MULTIPLIER: constant(uint256) = 10 ** 18

admin: public(address)  # Can and will be a smart contract
future_admin: public(address)  # Can and will be a smart contract

token: public(address)  # CRV token
voting_escrow: public(address)  # Voting escrow

# Gauge parameters
# All numbers are "fixed point" on the basis of 1e18
n_gauge_types: public(int128)
n_gauges: public(int128)
gauge_type_names: public(HashMap[int128, String[64]])

# Needed for enumeration
gauges: public(HashMap[int128, address])

# we increment values by 1 prior to storing them here so we can rely on a value
# of zero as meaning the gauge has not been set
gauge_types_: HashMap[address, int128]

vote_user_slopes: public(HashMap[address, HashMap[address, VotedSlope]])  # user -> gauge_addr -> VotedSlope
vote_user_power: public(HashMap[address, uint256])  # Total vote power used by user
last_user_vote: public(HashMap[address, HashMap[address, uint256]])  # Last user vote's timestamp for each gauge address

points_weight: public(HashMap[address, HashMap[uint256, Point]])
changes_weight: HashMap[address, HashMap[uint256, uint256]]
time_weight: HashMap[address, uint256]

points_sum: HashMap[int128, HashMap[uint256, Point]]
changes_sum: HashMap[int128, HashMap[uint256, uint256]]
time_sum: HashMap[int128, uint256]

points_total: public(HashMap[uint256, uint256])
time_total: public(uint256)

points_type_weight: HashMap[int128, HashMap[uint256, uint256]]
time_type_weight: HashMap[int128, uint256]


@external
def __init__(_token: address, _voting_escrow: address):
    self.admin = msg.sender
    self.token = _token
    self.voting_escrow = _voting_escrow
    self.time_total = block.timestamp / WEEK * WEEK


@external
def commit_transfer_ownership(addr: address):
    """
    @notice Transfer ownership of GaugeController to `addr`
    @param addr Address to have ownership transferred to
    """
    assert msg.sender == self.admin
    self.future_admin = addr
    log CommitOwnership(addr)


@external
def apply_transfer_ownership():
    assert msg.sender == self.admin
    _admin: address = self.future_admin
    self.admin = _admin
    log ApplyOwnership(_admin)


@external
@view
def gauge_types(_addr: address) -> int128:
    gauge_type: int128 = self.gauge_types_[_addr]
    assert gauge_type != 0

    return gauge_type - 1


@internal
def _get_type_weight(gauge_type: int128) -> uint256:
    # Filling all the type weights by week
    # and returning the NEAREST FUTURE value
    t: uint256 = self.time_type_weight[gauge_type]
    if t > 0:
        w: uint256 = self.points_type_weight[gauge_type][t]
        for i in range(500):
            if t > block.timestamp:
                break
            t += WEEK
            self.points_type_weight[gauge_type][t] = w
            if t > block.timestamp:
                self.time_type_weight[gauge_type] = t
        return w
    else:
        return 0


@internal
def _get_sum(gauge_type: int128) -> uint256:
    t: uint256 = self.time_sum[gauge_type]
    if t > 0:
        pt: Point = self.points_sum[gauge_type][t]
        for i in range(500):
            if t > block.timestamp:
                break
            t += WEEK
            d_bias: uint256 = pt.slope * WEEK
            if pt.bias > d_bias:
                pt.bias -= d_bias
                d_slope: uint256 = self.changes_sum[gauge_type][t]
                pt.slope -= d_slope
            else:
                pt.bias = 0
                pt.slope = 0
            self.points_sum[gauge_type][t] = pt
            if t > block.timestamp:
                self.time_sum[gauge_type] = t
        return pt.bias
    else:
        return 0


@internal
def _get_total() -> uint256:
    t: uint256 = self.time_total
    _n_gauge_types: int128 = self.n_gauge_types
    if t > 0:
        pt: uint256 = self.points_total[t]
        for i in range(500):
            if t > block.timestamp:
                break
            t += WEEK
            pt = 0
            # Scales as n_types * n_unckecked_weeks (hopefully 1 at most)
            for gauge_type in range(100):
                if gauge_type == _n_gauge_types:
                    break
                type_sum: uint256 = self._get_sum(gauge_type)
                type_weight: uint256 = self._get_type_weight(gauge_type)
                pt += type_sum * type_weight
            self.points_total[t] = pt

            if t > block.timestamp:
                self.time_total = t
        return pt
    else:
        return 0


@internal
def _get_weight(gauge_addr: address) -> uint256:
    t: uint256 = self.time_weight[gauge_addr]
    if t > 0:
        pt: Point = self.points_weight[gauge_addr][t]
        for i in range(500):
            if t > block.timestamp:
                break
            t += WEEK
            d_bias: uint256 = pt.slope * WEEK
            if pt.bias > d_bias:
                pt.bias -= d_bias
                d_slope: uint256 = self.changes_weight[gauge_addr][t]
                pt.slope -= d_slope
            else:
                pt.bias = 0
                pt.slope = 0
            self.points_weight[gauge_addr][t] = pt
            if t > block.timestamp:
                self.time_weight[gauge_addr] = t
        return pt.bias
    else:
        return 0


@external
def add_gauge(addr: address, gauge_type: int128, weight: uint256 = 0):
    """
    @notice Add gauge `addr` of type `gauge_type` with weight `weight`
    @param addr Gauge address
    @param gauge_type Gauge type
    @param weight Gauge weight
    """
    assert msg.sender == self.admin
    assert (gauge_type >= 0) and (gauge_type < self.n_gauge_types)
    assert self.gauge_types_[addr] == 0  # dev: cannot add the same gauge twice

    n: int128 = self.n_gauges
    self.n_gauges = n + 1
    self.gauges[n] = addr

    self.gauge_types_[addr] = gauge_type + 1

    if weight > 0:
        next_time: uint256 = (block.timestamp + WEEK) / WEEK * WEEK
        _type_weight: uint256 = self._get_type_weight(gauge_type)
        _old_sum: uint256 = self._get_sum(gauge_type)
        _old_total: uint256 = self._get_total()

        self.points_sum[gauge_type][next_time].bias = weight + _old_sum
        self.points_total[next_time] = _old_total + _type_weight * weight

        self.points_weight[addr][next_time].bias = weight
        self.time_weight[addr] = next_time

    # XXX log


@external
def checkpoint():
    self._get_total()


@internal
@view
def _gauge_relative_weight(addr: address, time: uint256) -> uint256:
    t: uint256 = 0
    if time == 0:
        t = block.timestamp / WEEK * WEEK
    else:
        t = time / WEEK * WEEK
    _total_weight: uint256 = self.points_total[t]

    if _total_weight > 0:
        gauge_type: int128 = self.gauge_types_[addr] - 1
        _type_weight: uint256 = self.points_type_weight[gauge_type][t]
        _gauge_weight: uint256 = self.points_weight[addr][t].bias
        return MULTIPLIER * _type_weight * _gauge_weight / _total_weight

    else:
        return 0


@external
def gauge_relative_weight_write(addr: address, time: uint256 = 0) -> uint256:
    """
    Same as gauge_relative_weight(), but also fill all the unfilled values
    for type and gauge records
    Everyone can call, however nothing is recorded if the values are filled already
    """
    self._get_weight(addr)
    self._get_total()  # Also calculates get_sum
    return self._gauge_relative_weight(addr, time)


@external
@view
def gauge_relative_weight(addr: address, time: uint256 = 0) -> uint256:
    """
    Same as gauge_relative_weight(), but also fill all the unfilled values
    for type and gauge records
    Everyone can call, however nothing is recorded if the values are filled already
    """
    return self._gauge_relative_weight(addr, time)


@internal
def _change_type_weight(type_id: int128, weight: uint256):
    old_weight: uint256 = self._get_type_weight(type_id)
    old_sum: uint256 = self._get_sum(type_id)
    _total_weight: uint256 = self._get_total()
    next_time: uint256 = (block.timestamp + WEEK) / WEEK * WEEK

    _total_weight = _total_weight + old_sum * weight - old_sum * old_weight
    self.points_total[next_time] = _total_weight
    self.points_type_weight[type_id][next_time] = weight
    self.time_total = next_time
    self.time_type_weight[type_id] = next_time

    log NewTypeWeight(type_id, next_time, weight, _total_weight)


@external
def add_type(_name: String[64], weight: uint256 = 0):
    """
    @notice Add gauge type with name `_name` and weight `weight`
    @param _name Name of gauge type
    @param weight Weight of gauge type
    """
    assert msg.sender == self.admin
    type_id: int128 = self.n_gauge_types
    self.gauge_type_names[type_id] = _name
    self.n_gauge_types = type_id + 1
    if weight != 0:
        self._change_type_weight(type_id, weight)


@external
def change_type_weight(type_id: int128, weight: uint256):
    """
    @notice Change gauge type `type_id` weight to `weight`
    @param type_id Gauge type id
    @param weight New Gauge weight
    """
    assert msg.sender == self.admin
    self._change_type_weight(type_id, weight)


@internal
def _change_gauge_weight(addr: address, weight: uint256):
    # Change gauge weight
    # Only needed when testing in reality
    gauge_type: int128 = self.gauge_types_[addr] - 1
    old_gauge_weight: uint256 = self._get_weight(addr)
    type_weight: uint256 = self._get_type_weight(gauge_type)
    old_sum: uint256 = self._get_sum(gauge_type)
    _total_weight: uint256 = self._get_total()
    next_time: uint256 = (block.timestamp + WEEK) / WEEK * WEEK

    self.points_weight[addr][next_time].bias = weight
    self.time_weight[addr] = next_time

    new_sum: uint256 = old_sum + weight - old_gauge_weight
    self.points_sum[gauge_type][next_time].bias = new_sum
    self.time_sum[gauge_type] = next_time

    _total_weight = _total_weight + new_sum * type_weight - old_sum * type_weight
    self.points_total[next_time] = _total_weight
    self.time_total = next_time

    log NewGaugeWeight(addr, block.timestamp, weight, _total_weight)


@external
def change_gauge_weight(addr: address, weight: uint256):
    assert msg.sender == self.admin
    self._change_gauge_weight(addr, weight)


@external
def vote_for_gauge_weights(_gauge_addr: address, _user_weight: uint256):
    """
    @notice Allocate voting power for changing pool weights
    @param _gauge_addr Gauge which `msg.sender` votes for
    @param _user_weight Weight for a gauge in bps (units of 0.01%). Minimal is 0.01%. Ignored if 0
    """
    escrow: address = self.voting_escrow
    slope: uint256 = convert(VotingEscrow(escrow).get_last_user_slope(msg.sender), uint256)
    lock_end: uint256 = VotingEscrow(escrow).locked__end(msg.sender)
    _n_gauges: int128 = self.n_gauges
    next_time: uint256 = (block.timestamp + WEEK) / WEEK * WEEK
    assert lock_end > next_time, "Your token lock expires too soon"
    assert (_user_weight >= 0) and (_user_weight <= 10000), "You used all your voting power"
    assert block.timestamp >= self.last_user_vote[msg.sender][_gauge_addr] + WEIGHT_VOTE_DELAY, "Cannot vote so often"

    gauge_type: int128 = self.gauge_types_[_gauge_addr] - 1
    assert gauge_type >= 0, "Gauge not added"
    # Prepare slopes and biases in memory
    old_slope: VotedSlope = self.vote_user_slopes[msg.sender][_gauge_addr]
    old_dt: uint256 = 0
    if old_slope.end > next_time:
        old_dt = old_slope.end - next_time
    old_bias: uint256 = old_slope.slope * old_dt
    new_slope: VotedSlope = VotedSlope({
        slope: slope * _user_weight / 10000,
        end: lock_end,
        power: _user_weight
    })
    new_dt: uint256 = lock_end - next_time  # dev: raises when expired
    new_bias: uint256 = new_slope.slope * new_dt

    # Check and update powers (weights) used
    power_used: uint256 = self.vote_user_power[msg.sender]
    power_used = power_used + new_slope.power - old_slope.power
    self.vote_user_power[msg.sender] = power_used
    assert (power_used >= 0) and (power_used <= 10000), 'Used too much power'

    ## Remove old and schedule new slope changes
    # Remove slope changes for old slopes
    # Schedule recording of initial slope for next_time
    old_weight_bias: uint256 = self._get_weight(_gauge_addr)
    old_weight_slope: uint256 = self.points_weight[_gauge_addr][next_time].slope
    old_sum_bias: uint256 = self._get_sum(gauge_type)
    old_sum_slope: uint256 = self.points_sum[gauge_type][next_time].slope

    self.points_weight[_gauge_addr][next_time].bias = max(old_weight_bias + new_bias, old_bias) - old_bias
    self.points_sum[gauge_type][next_time].bias = max(old_sum_bias + new_bias, old_bias) - old_bias
    if old_slope.end > next_time:
        self.points_weight[_gauge_addr][next_time].slope = max(old_weight_slope + new_slope.slope, old_slope.slope) - old_slope.slope
        self.points_sum[gauge_type][next_time].slope = max(old_sum_slope + new_slope.slope, old_slope.slope) - old_slope.slope
    else:
        self.points_weight[_gauge_addr][next_time].slope += new_slope.slope
        self.points_sum[gauge_type][next_time].slope += new_slope.slope
    if old_slope.end > block.timestamp:
        # Cancel old slope changes if they still didn't happen
        self.changes_weight[_gauge_addr][old_slope.end] -= old_slope.slope
        self.changes_sum[gauge_type][old_slope.end] -= old_slope.slope
    # Add slope changes for new slopes
    self.changes_weight[_gauge_addr][new_slope.end] += new_slope.slope
    self.changes_sum[gauge_type][new_slope.end] += new_slope.slope

    self._get_total()

    self.vote_user_slopes[msg.sender][_gauge_addr] = new_slope

    # Record last action time
    self.last_user_vote[msg.sender][_gauge_addr] = block.timestamp

    log VoteForGauge(block.timestamp, msg.sender, _gauge_addr, _user_weight)


@external
@view
def get_gauge_weight(addr: address) -> uint256:
    return self.points_weight[addr][self.time_weight[addr]].bias


@external
@view
def get_type_weight(type_id: int128) -> uint256:
    return self.points_type_weight[type_id][self.time_type_weight[type_id]]


@external
@view
def get_total_weight() -> uint256:
    return self.points_total[self.time_total]


@external
@view
def get_weights_sum_per_type(type_id: int128) -> uint256:
    return self.points_sum[type_id][self.time_sum[type_id]].bias
