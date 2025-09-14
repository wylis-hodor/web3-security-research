### [H-1] TITLE (Root Cause + Impact): Storing password on-chain makes it visible to anyone, and no longer private
H-1 the worse

**Description:**  All data stored on-chain is visible to anyone, and can be read directy from the blockcahin.  The `PasswordStore::s_password` variable is intended to be a private variable and only accessed through the `PasswordStore::getPassword` function, which is intended to be only called by the owner of the contract.

We show one such method of reading any data off chain below.

**Impact:** Anyone can read the private password, severly breaking the functionality of the protocol.

**Proof of Concept:**(Proof of Code) 

The below test case shows how anyone can read the password directly from the blockchain.

1. Create a locally running chain
```bash
make anvil
```

2. Deploy contract to chain
```bash
$ make deploy
passwordStore.setPassword("myPassword");
```

3. Run storage tool
```bash
$ cast storage 0x5FbDB2315678afecb367f032d93F642f64180aa3 1 --rpc-url http://127.0.0.1:8545
0x6d7950617373776f726400000000000000000000000000000000000000000014
```

Parse that hex string with:
```bash
$ cast parse-bytes32-string 0x6d7950617373776f726400000000000000000000000000000000000000000014
myPassword
```

**Recommended Mitigation:** Encrypt the password.

## Severity:
- Impact: HIGH
- Likelihood: HIGH
- HIGH + HIGH = CRIT


### [H-2] TITLE (Root Cause + Impact) : `PasswordStore::setPassword` is callable by anyone, meaning a non-owner could change the password

**Description:** he `PasswordStore::setPassword` function is set to be an `external` function, however the natspec of the function and overall purpose of the smart contract is that `This function allows only the owner to set a new password.`

```javascript
    function setPassword(string memory newPassword) external {
@>      // @audit - There are no access controls here
        s_password = newPassword;
        emit SetNetPassword();
    }
```

**Impact:** Anyone can set/change the password of the contract.

**Proof of Concept:** Add the following to the `PasswordStore.t.sol` test suite.

<details>
<summary>Code</summary>

```javascript
function test_anyone_can_set_password(address randomAddress) public {
    vm.prank(randomAddress);
    string memory expectedPassword = "myNewPassword";
    passwordStore.setPassword(expectedPassword);
    vm.prank(owner);
    string memory actualPassword = passwordStore.getPassword();
    assertEq(actualPassword, expectedPassword);
}
```

</details>

**Recommended Mitigation:** Add an access control modifier to the `setPassword` function. 

```javascript
if (msg.sender != s_owner) {
    revert PasswordStore__NotOwner();
}
```

## Severity:
- Impact: HIGH
- Likelihood: HIGH