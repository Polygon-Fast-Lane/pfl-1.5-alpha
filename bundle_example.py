import json
import requests
from web3 import Web3
import time
import eth_abi
from web3.datastructures import AttributeDict
from web3.middleware import geth_poa_middleware
from web3.datastructures import AttributeDict

ipc_provider = '/data/ipc/bor/bor.ipc'
web3 = Web3(Web3.IPCProvider(ipc_provider))
web3.middleware_onion.inject(geth_poa_middleware, layer=0)
BORSession = requests.Session()

PFL_DATA_FOLDER = "pfl_data"

SEARCHER_EOA_ADDRESS = ''
SEARCHER_EOA_PK = ''
SEARCHER_CONTRACT_ADDRESS = Web3.toChecksumAddress('')

pfl_alpha_relay_address = ''
pfl_alpha_api_username = ''
pfl_alpha_api_key = ''
pfl_contract_address = Web3.toChecksumAddress('')

pfl_participating_validators = set([
    Web3.toChecksumAddress('0x127685D6dD6683085Da4B6a041eFcef1681E5C9C'),
])

PFLSession = requests.Session()
PFLSession.auth = (pfl_alpha_api_username, pfl_alpha_api_key)

with open(f"{PFL_DATA_FOLDER}/pfl_jit_auction_abi.json") as x:
    fast_lane_ABI = json.load(x)
pfl_contract = web3.eth.contract(address=pfl_contract_address, abi=fast_lane_ABI)   

with open("searcher_contract_abi.json") as y:
    searcher_ABI = json.load(y)
searcher_contract = web3.eth.contract(address=SEARCHER_CONTRACT_ADDRESS, abi=searcher_ABI) 


class SearcherEOA:
    def __init__(self, searcherEOAAddress, searcherEOAPrivateKey):
        self.address = Web3.toChecksumAddress(searcherEOAAddress) # address of EOA
        self.privateKey = searcherEOAPrivateKey # private key of EOA
        self.nonce = int(web3.eth.get_transaction_count(searcherEOAAddress)) # nonce of EOA

    def update_nonce(self):
        self.nonce = int(web3.eth.get_transaction_count(self.address))

class OpportunityTx:
    def __init__(self, tx, txDict):
        self.tx = tx # AttributeDict of transaction from bor
        if 'gasPrice' in txDict:
            self.gasPrice = txDict['gasPrice'] # legacy tx parameter
            self.type = int(0)
        if 'maxPriorityFeePerGas' in txDict:
            self.maxPriorityFeePerGas = txDict['maxPriorityFeePerGas']
            self.type = int(2)
        if 'maxFeePerGas' in txDict:
            self.maxFeePerGas = txDict['maxFeePerGas']


def get_current_validator():
    rsp = BORSession.post("http://localhost:8545", json={
        "jsonrpc": "2.0",
        "method": "bor_getAuthor",
        "params": [],
        "id": 1,
    })
    try:
        validator = Web3.toChecksumAddress(rsp.json()["result"])
    except:
        validator = "err"
    print("validator:", validator)
    return validator

def build_searcher_transaction(
        searcherEOA: SearcherEOA, 
        opportunityTx: OpportunityTx, 
        validator: str):

    if opportunityTx.type == 0:
        searcherTxDict = {
            'from': searcherEOA.address,
            'gasPrice' : opportunityTx.gasPrice,
            'gas': int(500_000),
            'chainId': int(137),
            'nonce': searcherEOA.nonce,
            'to': searcherEOA.address,
            'data' : b'',
        }
    else:
        searcherTxDict = {
            'from': searcherEOA.address,
            'maxPriorityFeePerGas' : opportunityTx.maxPriorityFeePerGas,
            'maxFeePerGas' : opportunityTx.maxFeePerGas,
            'gas': int(500_000),
            'chainId': int(137),
            'nonce': searcherEOA.nonce,
            'to': searcherEOA.address,
            'data' : b'',
        }

    return web3.eth.account.sign_transaction(searcherTxDict, searcherEOA.privateKey)

def build_pfl_bid_transaction(bidAmount, searcherEOA, opportunityTx, validator):
    
    if opportunityTx.type == 0:
        submitBidTxDict = {
            'from': searcherEOA.address,
            'nonce': int(searcherEOA.nonce + 1),  
            # NOTE: the bid transaction happens AFTER the arbitrage/backrun transaction
            # it must come from the same EOA, have same gas price, and be one nonce higher
            'gasPrice' : opportunityTx.gasPrice,
            # NOTE: arbitrage/backrun transaction and PFL bid must both match the opportunity 
            # transaction's type and gas price parameters
            'gas': int(500_000),
            'value': int(bidAmount), 
            # NOTE: bid amount is not decimal formatted. To bid one matic, you'd bid 1 * 10**18
            'chainId': int(137),
        }
    else:
        submitBidTxDict = {
            'from': searcherEOA.address,
            'nonce': int(searcherEOA.nonce + 1),  
            # NOTE: the bid transaction happens AFTER the arbitrage/backrun transaction
            # it must come from the same EOA, have same gas price, and be one nonce higher
            'maxPriorityFeePerGas' : opportunityTx.maxPriorityFeePerGas,
            'maxFeePerGas' : opportunityTx.maxFeePerGas,
            # NOTE: arbitrage/backrun transaction and PFL bid must both match the opportunity 
            # transaction's type and gas price parameters
            'gas': int(500_000),
            'value': int(bidAmount), 
            # NOTE: bid amount is not decimal formatted. To bid one matic, you'd bid 1 * 10**18
            'chainId': int(137),
        }

    opportunityTxHash = eth_abi.encode_single('bytes32', opportunityTx.tx.hash)

    submitBidData = pfl_contract.functions.submitBid(
        opportunityTxHash,
        Web3.toChecksumAddress(validator),
        Web3.toChecksumAddress(searcherEOA.address)
    ).buildTransaction(submitBidTxDict)
    return web3.eth.account.sign_transaction(submitBidData, searcherEOA.privateKey)

def build_bundle(bidAmount, searcherEOA, opportunityTx, validator):

    signedSearcherTx = build_searcher_transaction(searcherEOA, opportunityTx, validator)
    signedSubmitBidTx = build_pfl_bid_transaction(bidAmount, searcherEOA, opportunityTx, validator)

    return [
        opportunityTx.tx.rawTransaction.hex(),
        signedSearcherTx.rawTransaction.hex(),
        signedSubmitBidTx.rawTransaction.hex(),
    ]

def send_bundle(searcher_bundle):
    rsp = PFLSession.post(pfl_alpha_relay_address, json={
        "jsonrpc": "2.0",
        "method": "pfl_addSearcherBundle",
        "params": [searcher_bundle],
        "id": 1,
    })
    try:
        return rsp.json()["result"]
    except Exception as exc:
        return f'err - {exc}'
        
def main():
    bidAmount = 1 * 10**17
    searcherEOA = SearcherEOA(SEARCHER_EOA_ADDRESS, SEARCHER_EOA_PK)
    opportunityTx = build_fake_opportunity_transaction()
    validator = get_current_validator()
    if validator in pfl_participating_validators:
        pfl_bundle = build_bundle(bidAmount, searcherEOA, opportunityTx, validator)
        bundle_result = send_bundle(pfl_bundle)
        print("result:",json.dumps(bundle_result, indent=2))

if __name__ == "__main__":
    main()