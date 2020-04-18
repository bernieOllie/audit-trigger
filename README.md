# Enhanced Audit Logging With PostgreSQL :elephant:

A customisable table audit system **with support for weak tables**, implemented using triggers and recursion.

---
## Retrieve audit information from a primary table and its related (weak) ones with a simple SELECT query

Just run the script `audit.sql`, then register each table desired for audit logging with a single function call - "audit_table" or its adapters, "audit_strong_table" or "audit_weak_table" - informing 
any column that should have its changes ignored, if any.

For tables of primary entities, it is necessary to pass as argument the name of the column that has unique, (most times) business-layer-meaningful value that identifies the entities in them. Such column is referred to as "code column". The values present in the code column of the table being audited are called "code values".

For registering tables that have no meaning independent of primary ones - referred to as "weak tables" - it is necessary to pass array(s) with relationship information of the related primary one(s), which means passing in each array:

- schema and name of primary table
- "relationship direction": if weak table points to strong one, it is called 'DIRECT' relation; if strong points to weak, it is called 'INVERSE'
- it is also necessary to inform which column has the foreign key constraint that links them

Due to relational integrity constraints of this audit system,
make sure to register primary tables before their related weak ones.

And that is it! You are now capable of retrieving audit information from the primary table and its weaker ones with a simple SELECT query on table "audit.logged_actions", by filtering through the code value of the primary one.

### Check out the full story behind this implementation, including a working example, at:

https://medium.com/@oliveira.bernardocb/make-auditing-meaningful-again-c9fbcc18276f

### Based on:

http://wiki.postgresql.org/wiki/Audit_trigger_91plus
