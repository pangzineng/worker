BEGIN;
-- Create the tables
create table :SCHEMA_NAME.job_queues (
  queue_name text not null primary key,
  job_count int not null,
  locked_at timestamptz,
  locked_by text
);
alter table :SCHEMA_NAME.job_queues enable row level security;

create table :SCHEMA_NAME.jobs (
  id bigserial primary key,
  queue_name text default (public.gen_random_uuid())::text not null,
  task_identifier text not null,
  payload json default '{}'::json not null,
  priority int default 0 not null,
  run_at timestamptz default now() not null,
  attempts int default 0 not null,
  max_attempts int default 25 not null,
  last_error text,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now()
);
alter table :SCHEMA_NAME.jobs enable row level security;

create index on :SCHEMA_NAME.jobs (priority, run_at, id);

-- Keep updated_at up to date
create function :SCHEMA_NAME.tg__update_timestamp() returns trigger as $$
begin
  new.updated_at = greatest(now(), old.updated_at + interval '1 millisecond');
  return new;
end;
$$ language plpgsql;
create trigger _100_timestamps before update on :SCHEMA_NAME.jobs for each row execute procedure :SCHEMA_NAME.tg__update_timestamp();

-- Manage the job_queues table - creating and deleting entries as appropriate
create function :SCHEMA_NAME.jobs__decrease_job_queue_count() returns trigger as $$
declare
  v_new_job_count int;
begin
  update :SCHEMA_NAME.job_queues
    set job_count = job_queues.job_count - 1
    where queue_name = old.queue_name
    returning job_count into v_new_job_count;

  if v_new_job_count <= 0 then
    delete from :SCHEMA_NAME.job_queues where queue_name = old.queue_name and job_count <= 0;
  end if;

  return old;
end;
$$ language plpgsql;
create function :SCHEMA_NAME.jobs__increase_job_queue_count() returns trigger as $$
begin
  insert into :SCHEMA_NAME.job_queues(queue_name, job_count)
    values(new.queue_name, 1)
    on conflict (queue_name)
    do update
    set job_count = job_queues.job_count + 1;

  return new;
end;
$$ language plpgsql;
create trigger _500_increase_job_queue_count after insert on :SCHEMA_NAME.jobs for each row execute procedure :SCHEMA_NAME.jobs__increase_job_queue_count();
create trigger _500_decrease_job_queue_count after delete on :SCHEMA_NAME.jobs for each row execute procedure :SCHEMA_NAME.jobs__decrease_job_queue_count();
create trigger _500_increase_job_queue_count_update after update of queue_name on :SCHEMA_NAME.jobs for each row execute procedure :SCHEMA_NAME.jobs__increase_job_queue_count();
create trigger _500_decrease_job_queue_count_update after update of queue_name on :SCHEMA_NAME.jobs for each row execute procedure :SCHEMA_NAME.jobs__decrease_job_queue_count();

-- Notify worker of new jobs
create function :SCHEMA_NAME.tg_jobs__notify_new_jobs() returns trigger as $$
begin
  perform pg_notify('jobs:insert', '');
  return new;
end;
$$ language plpgsql;
create trigger _900_notify_worker after insert on :SCHEMA_NAME.jobs for each statement execute procedure :SCHEMA_NAME.tg_jobs__notify_new_jobs();

-- Function to queue a job
create function :SCHEMA_NAME.add_job(identifier text, payload json = '{}', queue_name text = public.gen_random_uuid()::text, run_at timestamptz = now(), max_attempts int = 25) returns :SCHEMA_NAME.jobs as $$
  insert into :SCHEMA_NAME.jobs(task_identifier, payload, queue_name, run_at, max_attempts) values(identifier, payload, queue_name, run_at, max_attempts) returning *;
$$ language sql;

-- The main function - find me a job to do!
create function :SCHEMA_NAME.get_job(worker_id text, task_identifiers text[] = null, job_expiry interval = interval '4 hours') returns :SCHEMA_NAME.jobs as $$
declare
  v_job_id bigint;
  v_queue_name text;
  v_default_job_max_attempts text = '25';
  v_row :SCHEMA_NAME.jobs;
begin
  if worker_id is null or length(worker_id) < 10 then
    raise exception 'invalid worker id';
  end if;

  select job_queues.queue_name, jobs.id into v_queue_name, v_job_id
    from :SCHEMA_NAME.jobs
    inner join :SCHEMA_NAME.job_queues using (queue_name)
    where (locked_at is null or locked_at < (now() - job_expiry))
    and run_at <= now()
    and attempts < max_attempts
    and (task_identifiers is null or task_identifier = any(task_identifiers))
    order by priority asc, run_at asc, id asc
    limit 1
    for update of job_queues
    skip locked;

  if v_queue_name is null then
    return null;
  end if;

  update :SCHEMA_NAME.job_queues
    set
      locked_by = worker_id,
      locked_at = now()
    where job_queues.queue_name = v_queue_name;

  update :SCHEMA_NAME.jobs
    set attempts = attempts + 1
    where id = v_job_id
    returning * into v_row;

  return v_row;
end;
$$ language plpgsql;

-- I was successful, mark the job as completed
create function :SCHEMA_NAME.complete_job(worker_id text, job_id bigint) returns :SCHEMA_NAME.jobs as $$
declare
  v_row :SCHEMA_NAME.jobs;
begin
  delete from :SCHEMA_NAME.jobs
    where id = job_id
    returning * into v_row;

  update :SCHEMA_NAME.job_queues
    set locked_by = null, locked_at = null
    where queue_name = v_row.queue_name and locked_by = worker_id;

  return v_row;
end;
$$ language plpgsql;

-- I was unsuccessful, re-schedule the job please
create function :SCHEMA_NAME.fail_job(worker_id text, job_id bigint, error_message text) returns :SCHEMA_NAME.jobs as $$
declare
  v_row :SCHEMA_NAME.jobs;
begin
  update :SCHEMA_NAME.jobs
    set
      last_error = error_message,
      run_at = greatest(now(), run_at) + (exp(least(attempts, 10))::text || ' seconds')::interval
    where id = job_id
    returning * into v_row;

  update :SCHEMA_NAME.job_queues
    set locked_by = null, locked_at = null
    where queue_name = v_row.queue_name and locked_by = worker_id;

  return v_row;
end;
$$ language plpgsql;

COMMIT;
