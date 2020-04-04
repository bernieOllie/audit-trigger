CREATE SCHEMA example_factory;
REVOKE ALL ON SCHEMA example_factory FROM public;

COMMENT ON SCHEMA example_factory IS 'Example schema of a make-believe factory, for the sake of testing auditing of weak entities';

CREATE TABLE example_factory.formula (
    id bigserial primary key,
    expression text not null
);

REVOKE ALL ON example_factory.formula FROM public;

COMMENT ON TABLE example_factory.formula IS 'Instance of algebraic expression for Meter or KPI';
COMMENT ON COLUMN example_factory.formula.id IS 'Unique identifier for formula';
COMMENT ON COLUMN example_factory.formula.expression IS 'Algebraic expression that usually depends on signal aliases';

CREATE TABLE example_factory.signal (
    id bigserial primary key,
    alias text not null,
    formula_id int references example_factory.formula(id) not null
);

REVOKE ALL ON example_factory.signal FROM public;

COMMENT ON TABLE example_factory.signal IS 'Representation of an imaginary signal coming from the make-believe factory';
COMMENT ON COLUMN example_factory.signal.id IS 'Unique identifier for formula alias';
COMMENT ON COLUMN example_factory.signal.alias IS 'Text representation of the signal';
COMMENT ON COLUMN example_factory.signal.formula_id IS 'Identifier of the formula to which the alias belong';

CREATE TABLE example_factory.meter (
    id bigserial primary key,
    code text unique not null,
    description text,
    formula_id int references example_factory.formula(id)
);

REVOKE ALL ON example_factory.meter FROM public;

COMMENT ON TABLE example_factory.meter IS 'Meter of field equipment of the make-believe factory';
COMMENT ON COLUMN example_factory.meter.id IS 'Unique identifier for meter';
COMMENT ON COLUMN example_factory.meter.code IS 'Unique, human-attributed text identifier for meter';
COMMENT ON COLUMN example_factory.meter.description IS 'Description of meter';
COMMENT ON COLUMN example_factory.meter.formula_id IS 'Identifier of the formula that expresses the value of meter';

CREATE TABLE example_factory.kpi (
    id bigserial primary key,
    name text unique not null,
    description text,
    formula_id int references example_factory.formula(id)
);

REVOKE ALL ON example_factory.kpi FROM public;

COMMENT ON TABLE example_factory.kpi IS 'Key Performance Indicator (KPI) of a metric of the make-believe factory';
COMMENT ON COLUMN example_factory.kpi.id IS 'Unique identifier for KPI';
COMMENT ON COLUMN example_factory.kpi.name IS 'Unique, human-attributed text identifier for KPI';
COMMENT ON COLUMN example_factory.kpi.description IS 'Description of KPI';
COMMENT ON COLUMN example_factory.kpi.formula_id IS 'Identifier of the formula that expresses the value of KPI';
