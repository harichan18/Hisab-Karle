# Hisab Kitab

### More than an expense tracker. More than a regular *hisab-kitab*.

**Hisab Kitab** is a personal finance management application designed to make it easy to track money given to friends, money received from friends, daily expenses, and personal balances in one place.

The goal is simple:

> **Know where your money is going, who owes you, and how much you actually have.**

---

## Overview

Managing small transactions between friends can quickly become confusing.

You might give ₹500 to a friend, receive ₹200 back, spend ₹150 on food, and later forget exactly how much is still pending.

Hisab Kitab solves this by keeping a structured record of transactions and providing a clear overview of your financial activity.

---

## Features

### Friend-wise Money Tracking

Keep a separate transaction history for every friend.

Track:

* Money you gave
* Money you received
* Transaction notes
* Transaction date
* Current balance with each friend

### Give and Receive Transactions

Quickly record transactions using simple actions.

```text
                 YOUR MONEY
                     │
          ┌──────────┴──────────┐
          ↓                     ↓
   PERSONAL EXPENSES      PEER TRANSACTIONS
          │                     │
          ↓                GIVE / RECEIVE
          │                     │
          └──────────┬──────────┘
                     ↓
              FINANCIAL SUMMARY
                     │
              HISTORY & REPORTS
```

## Tech Stack

| Technology            | Purpose                 |
| --------------------- | ----------------------- |
| Flutter / Dart        | Application development |
| SQLite                | Local data storage      |
| Cloudinary            | Payment proof storage   |
| PDF Libraries         | Report generation       |
| Device Authentication | App security            |

## Getting Started

```bash
git clone https://github.com/harichan18/Hisab-Kitab.git
cd Hisab-Kitab
flutter pub get
flutter run
```

For Chrome:

```bash
flutter run -d chrome
```

For an Android device:

```bash
flutter devices
flutter run
```

---

## Local Database

Hisab Kitab uses SQLite for storing transaction information locally.

A transaction can contain information such as:

```text
Transaction
|
+-- ID
+-- Friend ID
+-- Amount
+-- Type
+-- Note
+-- Date
+-- Attachment
```

This allows the application to work with locally stored financial data without requiring a constant internet connection for basic functionality.

---

## Transaction Logic

The application distinguishes between money given and money received.

For example:

```text
You give Rahul ₹500

Rahul
Balance: +₹500
```

If Rahul returns ₹200:

```text
Rahul
Given:      ₹500
Received:   ₹200
Pending:    ₹300
```

This makes the outstanding amount easy to understand.

---

## UI Design Philosophy

Hisab Kitab focuses on a simple, clean, and practical interface.

The main design goals are:

* Minimal number of steps
* Clear financial information
* Easy transaction entry
* Friend-wise organization
* Mobile-first interface
* Easy-to-read balances
* Consistent visual hierarchy

---

## Future Improvements

* [ ] Advanced monthly analytics
* [ ] Expense categories
* [ ] Spending charts
* [ ] Monthly financial reports
* [ ] Automatic cloud synchronization
* [ ] Multi-device synchronization
* [ ] UPI deep links
* [ ] Payment reminders
* [ ] Recurring transactions
* [ ] CSV export
* [ ] Improved biometric security
* [ ] Dark and light themes
* [ ] Search and filter transactions
* [ ] Monthly spending limits
* [ ] Financial insights

---

## Project Goals

Hisab Kitab is being developed to provide a lightweight alternative to complicated expense-management applications.

The primary goals are:

**Simple. Fast. Private. Useful.**

Instead of trying to become a full-scale banking application, Hisab Kitab focuses on solving a common everyday problem:

> **Keeping track of small personal transactions without the headache of maintaining them manually.**

---

## Developer

**Harichan Kushwaha**
B.Tech Information Technology
Vishwakarma Institute of Technology, Pune

---

### Hisab Kitab

**Not just an expense tracker.
Not just a digital ledger.
A complete picture of your money.**
