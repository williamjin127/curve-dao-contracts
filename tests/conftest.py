import pytest
from eth_tester import EthereumTester, PyEVMBackend
from web3 import Web3
from os.path import realpath, dirname, join
from .deploy import deploy_contract

CONTRACT_PATH = join(dirname(dirname(realpath(__file__))), 'vyper')


def block_timestamp(w3):
    return w3.eth.getBlock(w3.eth.blockNumber)['timestamp']


def time_travel(w3, dt):
    w3.testing.timeTravel(block_timestamp(w3) + dt)
    return block_timestamp(w3)


def theoretical_supply(w3, token):
    epoch = token.caller.mining_epoch()
    q = 1 / 2 ** .5
    rdt = 594661989 // (365 * 86400) * (365 * 86400)
    S = 10 ** 9 * 10 ** 18
    if epoch > 0:
        S += int(rdt * (1 - q ** epoch) / (1 - q))
    S += (rdt // (365 * 86400)) * (block_timestamp(w3) - token.caller.start_epoch_time() + 1)
    return S


@pytest.fixture
def tester():
    genesis_params = PyEVMBackend._generate_genesis_params(overrides={'gas_limit': 7 * 10 ** 6})
    pyevm_backend = PyEVMBackend(genesis_parameters=genesis_params)
    pyevm_backend.reset_to_genesis(genesis_params=genesis_params, num_accounts=10)
    return EthereumTester(backend=pyevm_backend, auto_mine_transactions=True)


@pytest.fixture
def w3(tester):
    w3 = Web3(Web3.EthereumTesterProvider(tester))
    w3.eth.setGasPriceStrategy(lambda web3, params: 0)
    w3.eth.defaultAccount = w3.eth.accounts[0]
    return w3


@pytest.fixture
def token(w3):
    return deploy_contract(
                w3, 'ERC20Mintable.vy', w3.eth.accounts[0],
                b'Curve DAO token', b'CRV', 18, 10 ** 9)
