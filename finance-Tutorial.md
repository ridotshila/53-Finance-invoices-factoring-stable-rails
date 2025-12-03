# 📘 **Invoice Factoring Smart Contract – Full Tutorial (`invoice-factor-plutus.plutus`)**

This tutorial explains the design, logic, workflow, and security considerations behind your Invoice Factoring validator. It is written in a clear, educational format that matches your earlier Vesting and Shipment tutorials.

---

## 📚 **Table of Contents**

1. [📦 Purpose of the Contract](#1-purpose-of-the-contract)
2. [📄 Data Types](#2-data-types)

   * InvoiceDatum
   * InvoiceAction
3. [🛠️ Helper Functions Explained](#3-helper-functions-explained)
4. [🧠 Core Validator Logic](#4-core-validator-logic)

   * AssignTo
   * Pay
   * MarkPaid
   * Cancel
5. [🔐 Signature & Compliance Rules](#5-signature--compliance-rules)
6. [💰 Stable Token Settlement Logic](#6-stable-token-settlement-logic)
7. [⚙️ Script Compilation & Output](#7-script-compilation--output)
8. [🏗️ Off-chain Workflow](#8-off-chain-workflow)
9. [🧪 Testing Strategy](#9-testing-strategy)
10. [📘 Glossary](#10-glossary)

---

## 1. 📦 **Purpose of the Contract**

This validator implements an **invoice settlement and factoring** mechanism where:

* A supplier issues an invoice to a buyer
* The invoice may be **assigned to a factor** (an investor who buys invoices)
* The buyer settles the invoice using **stable tokens**
* A **KYC authority signature** is required for regulated stable-token transactions
* Issuer can **mark invoices paid** or **cancel** them
* On-chain payment goes to **issuer or factor** depending on assignment

It supports:

✔️ Traditional invoice settlement
✔️ Invoice factoring
✔️ Regulated stable-asset settlements
✔️ Accounting & off-chain reconciliation

---

## 2. 📄 **Data Types**

### 🧾 **InvoiceDatum**

Each UTxO stores an invoice with fields:

| Field                         | Meaning                                     |
| ----------------------------- | ------------------------------------------- |
| `invIssuer`                   | Supplier issuing the invoice                |
| `invBuyer`                    | Buyer responsible for payment               |
| `invAmount`                   | Amount owed, in stable token smallest units |
| `invDue`                      | POSIX due date                              |
| `invPaid`                     | Boolean marking invoice as paid             |
| `invHash`                     | Off-chain invoice reference hash            |
| `invAssignedTo`               | Factor PKH if sold, otherwise Nothing       |
| `invStableCS` / `invStableTN` | CurrencySymbol & TokenName of stable asset  |
| `invKycAuth`                  | PubKeyHash of compliance authority          |

These combine both **financial state** and **compliance state**.

---

### 🔄 **InvoiceAction**

Redeemers representing allowed actions:

* `AssignTo factorPkh`
* `Pay amountPaid paidAt`
* `MarkPaid`
* `Cancel`

Each action activates a unique validation path.

---

## 3. 🛠️ **Helper Functions Explained**

### **`pubKeyHashAddress`**

Constructs a scriptless address belonging to a PKH.
Used to detect payments sent to issuer/factor.

---

### **`valuePaidTo`**

Reads how many **stable tokens** were paid to a target address in the transaction.

This function enforces:

* The correct asset (stable token) was paid
* A minimum amount landed in the recipient output

---

### **`nowInRange` / `isPastDue`**

Ensures the transaction includes a valid time where `paidAt` is reachable.

Required for:

* Deadline logic
* Preventing timestamp forgery
* Auditable settlement dates

---

## 4. 🧠 **Core Validator Logic**

The heart of the contract: `mkInvoiceValidator`.

---

### 🟦 **A. AssignTo factor**

Used when issuer sells the invoice to a factor.

**Rules enforced:**

1. Only issuer may assign:

   ```haskell
   txSignedBy info (invIssuer inv)
   ```
2. Cannot assign an already-paid invoice:

   ```haskell
   not (invPaid inv)
   ```

After this action, future payments will go to the factor.

---

### 🟩 **B. Pay amountPaid paidAt**

This is the most important path: **buyer settles the invoice**.

Validation requires:

#### ✔️ Buyer must sign

Ensures payment authorization.

#### ✔️ amountPaid >= invAmount

Partial payments are allowed off-chain but validator enforces minimum.

#### ✔️ Payment timestamp must be valid

`nowInRange info paidAt`

#### ✔️ Payment must deliver stable tokens to correct recipient

Recipient = `factor` OR `issuer`, depending on assignment.

```haskell
valuePaidTo info recipient >= invAmount
```

#### ✔️ KYC authority must sign

This enforces compliance:

```haskell
txSignedBy info (invKycAuth inv)
```

This rule ensures stable settlements cannot execute without external approval (e.g., FX checks, AML checks, compliance logs).

---

### 🟨 **C. MarkPaid**

Issuer can mark invoice paid even if:

* Payment happens off-chain
* Bank rails used
* Off-chain settlement is verified

Rule:

* Only issuer can perform this action.

---

### 🟥 **D. Cancel**

Issuer cancels the invoice IF:

* They sign
* Invoice not yet paid

This prevents voiding after completion.

---

## 5. 🔐 **Signature & Compliance Rules**

| Action   | Required Signature    |
| -------- | --------------------- |
| AssignTo | Issuer                |
| Pay      | Buyer + KYC Authority |
| MarkPaid | Issuer                |
| Cancel   | Issuer                |

The KYC signature requirement is the biggest differentiator—this contract is compliant-friendly.

---

## 6. 💰 **Stable Token Settlement Logic**

Stable payments are validated by:

1. Checking correct asset (CS/TN)
2. Verifying amount ≥ invoice amount
3. Requiring KYC signature
4. Enforcing buyer signature

This provides:

* On-chain settlement finality
* Proof-of-payment
* AML/KYC enforced payments
* Factoring-compatible routing

---

## 7. ⚙️ **Script Compilation & Output**

At the bottom of the file:

```haskell
saveValidator
```

Does:

1. Serialises the compiled validator
2. Writes it to `invoice-factor-plutus.plutus`
3. Produces a deployable V2 script file

This is the file used for:

* Cardano-cli
* Mesh, Lucid, Helios apps
* DApps, backends, and explorers

---

## 8. 🏗️ **Off-chain Workflow**

### **1. Issuer creates invoice UTxO**

* Contains full `InvoiceDatum`
* Locks a small ADA amount

### **2. Optional: Issuer assigns invoice**

Redeemer: `AssignTo pkhFactor`

### **3. Buyer pays invoice**

Redeemer: `Pay amount timestamp`

Off-chain code ensures:

* Stable tokens included in outputs
* Sent to factor or issuer
* KYC authority signs

### **4. Issuer marks paid**

Redeemer: `MarkPaid`

### **5. Issuer can cancel**

Redeemer: `Cancel`

---

## 9. 🧪 **Testing Strategy**

Test cases recommended:

### ✔️ AssignTo

* Invoice already paid → should fail
* Non-issuer attempts → fail

### ✔️ Pay

* Wrong asset → fail
* Insufficient amount → fail
* Missing KYC signature → fail
* Buyer signs → success

### ✔️ MarkPaid

* Non-issuer signs → fail

### ✔️ Cancel

* After paid → should fail
* Non-issuer → fail

---

## 10. 📘 **Glossary**

| Term              | Meaning                                         |
| ----------------- | ----------------------------------------------- |
| **Factoring**     | Selling an invoice to a financier               |
| **Issuer**        | Supplier issuing the invoice                    |
| **Buyer**         | Debtor who owes payment                         |
| **Factor**        | Third party who buys invoices                   |
| **KYC Authority** | Verified legal compliance signer                |
| **Stable Token**  | Token representing fiat or low-volatility asset |
| **Redeemer**      | Indicates the action being executed             |
| **Datum**         | Holds invoice state                             |

---

