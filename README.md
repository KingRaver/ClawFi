# ClawFi Encryption System

## Overview

The ClawFi Encryption System is an advanced, comprehensive cryptographic security framework uniquely designed for the ClawFi gaming platform. It provides state-of-the-art encryption, key management, and data integrity mechanisms to secure sensitive gaming, financial, and operational data with enterprise-grade robustness.

This system ensures secure handling of prize pools, user financials, gameplay telemetry, API credentials, and audit trails while seamlessly integrating wallet-based authentication and advanced cryptographic algorithms to maintain the highest levels of trust and compliance in the gaming ecosystem.

---

## Key Features

### 1. ClawFi-Specific Encryption Methods

- **Prize Data Protection:** Secure encryption of prize pool information including values, rarity calculations, and contributor identities.
- **User Financial Security:** Safeguards credit balances, transaction histories, and payment details from unauthorized access.
- **Game Session Encryption:** Protects session data such as win/loss outcomes, timing patterns, and gameplay analytics to ensure fairness and privacy.
- **API Credential Protection:** Encrypts sensitive provider keys, service tokens, and authentication data used in third-party integrations.
- **Database Field Encryption:** Enables transparent encryption of sensitive columns within your PostgreSQL database for secure storage.

### 2. Wallet Integration & Compatibility

- **Wallet Signature Encryption:** Derives cryptographic keys from existing wallet authentication signatures, reinforcing decentralized security.
- **Message Signer Integration:** Fully compatible with your `message_signer.py`, allowing smooth cryptographic workflows.
- **Signature Verification:** Ensures encrypted data authenticity by verifying creation with specific wallet signatures.
- **ETH Account Support:** Deep integration with the `eth_account` Python library for Ethereum account management and signing.

### 3. Advanced Cryptographic Algorithms

- **AES-256-GCM:** Primary authenticated encryption mode providing confidentiality and integrity with minimal overhead.
- **ChaCha20-Poly1305:** Offers high-performance encryption ideal for frequent or latency-sensitive operations.
- **AES-256-CBC + HMAC:** Legacy support combining CBC mode encryption with HMAC-based authentication.
- **Fernet:** Provides timestamped encryption with built-in expiration and tamper protection.

### 4. Enterprise Key Management

- **Master Key Derivation:** Secure hierarchical key derivation using HKDF for robust diversified keys.
- **Key Rotation:** Automated rotation and version management support to enhance forward security.
- **Purpose-Specific Keys:** Isolates keys based on use case (e.g., prize data, user financials, game sessions) for enhanced compartmentalization.
- **Database Integration:** Stores key metadata securely in PostgreSQL for traceable key management.
- **Redis Caching:** Uses Redis for high-performance caching of frequently used keys to reduce latency.

### 5. Advanced Security Features

- **Multiple Key Derivation Functions (KDFs):** Supports Argon2, PBKDF2, Scrypt, and HKDF tailored for different security and performance needs.
- **Data Compression:** Automatically compresses large data before encryption to optimize storage and transmission efficiency.
- **Integrity Verification:** Implements SHA-256 checksums to detect any tampering with encrypted data.
- **Secure Deletion:** Memory-safe practices for sensitive key cleanup and destruction.
- **Usage Tracking:** Maintains detailed logs and statistics of encryption operations for auditing and monitoring.

### 6. ClawFi Revenue & Gaming Security

- **Revenue Distribution Protection:** Encrypts public goods fund allocations and contributor payment data to prevent leakage or manipulation.
- **Game Fairness Data:** Secures win probability calculations, prize pool mechanics, and randomness sources.
- **Audit Trail Encryption:** Protects the integrity and confidentiality of gaming operation logs for compliance and fraud detection.
- **Multi-tenant Security:** Supports user-specific encryption keys to ensure tenant data isolation in multi-user environments.

---

## Architecture & Design

The ClawFi Encryption System is architected to provide modular, extensible encryption utilities tailored specifically to gaming platform needs:

- **Utils Module:** Implements core encryption and decryption functions with configurable algorithms and keys.
- **Key Management:** Secure master key generation, rotation, and metadata management integrated tightly with PostgreSQL and Redis.
- **Wallet Integration:** Leverages Ethereum wallet signatures for strong cryptographic key derivation and authentication.
- **Data Layers:** Transparent encryption wrappers for API credentials, prize data, sessions, and sensitive database fields.
- **Security Layers:** Enforced integrity checks, secure deletion patterns, and audit logging enhance trust and compliance.

---

## Installation

```
# Clone the repo or copy utils/encryption.py to your project
git clone https://github.com/kingraver/clawfi_encryption.git

# Install dependencies including eth_account and cryptography
pip install eth_account cryptography redis psycopg2-binary
```

---

## Usage Examples

### Encrypt Prize Data

```
from utils.encryption import encrypt_prize_data

prize_info = {
    "pool_value": 100000,
    "rarity": "legendary",
    "contributors": ["0xabc...", "0xdef..."]
}

encrypted = encrypt_prize_data(prize_info, user_wallet_signature)
print("Encrypted prize data:", encrypted)
```

### Decrypt User Financial Info

```
from utils.encryption import decrypt_user_financials

decrypted = decrypt_user_financials(encrypted_financial_data, user_wallet_signature)
print("User financials:", decrypted)
```

### Key Rotation

```
from utils.encryption import rotate_keys

rotate_keys(new_master_seed)
```

---

## Security Best Practices

- Always use secure channels (TLS) to transmit encrypted data.
- Regularly rotate master keys using the built-in rotation utilities.
- Ensure `message_signer.py` securely manages wallet signatures.
- Monitor encryption usage logs for anomalies or suspicious activity.
- Test integration points for wallet compatibility and signature verifications.

---

## Contributing

Contributions, issues, and feature requests are welcome! Feel free to submit pull requests or open issues to improve the system.

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## Contact & Support

For further support or inquiries about ClawFi Encryption System integration, please contact the ClawFi development team or visit our community channels.

---

ClawFi Encryption System: Protecting your game, your users, and public goods with cryptographic excellence.
