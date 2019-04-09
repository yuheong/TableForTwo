DROP SCHEMA public CASCADE;
CREATE SCHEMA public;

-- FUNCTIONS FOR SEARCH FEATURE --
create EXTENSION if not exists pg_trgm;
create or replace function
  inlineMax(val1 real, val2 real)
returns real
as $$
begin
  if val1 > val2 then
    return val1;
  end if;
  return val2;
end;
$$
language plpgsql;
-- END --

create table Users(
  id serial primary key,
  name varchar(50) not null,
  username varchar(50) unique not null,
  password varchar(200) not null,
  role varchar(20) default 'CUSTOMER' not null
);

create table Customers(
  id integer primary key,
  foreign key(id) references Users(id)
);

create table BranchOwner (
 id integer primary key,
 foreign key(id) references Users(id)
);

create or replace function insertNewUserIntoCustomers()
returns trigger as 
$$
begin
	insert into customers(id) values(new.id);
	if new.role = 'BRANCH_OWNER' then
		insert into branchowner(id) values(new.id);
	end if;

	return new;
end;
$$
language plpgsql;

-- All signed up user is automatically a customer.
create trigger insertNewUserIntoCustomers
	after insert on Users
	for each row 
	execute procedure insertNewUserIntoCustomers();

create table Restaurants(
  id       serial primary key,
  rName     varchar(100) not null,
  rPhone    bigint,
  rAddress  varchar(100)
);

create table Branches(
  id       serial primary key,
  restaurant_id	integer not null,
  branch_owner_id integer not null,

  bName     varchar(100),
  bPhone    bigint,
  bAddress  varchar(100), --eg: 1A Kent Ridge Road
  bArea     varchar(100), --eg: South
  openingHour time not null,
  
  foreign key(branch_owner_id) references BranchOwner(id),
  foreign key(restaurant_id) references Restaurants(id) on delete cascade
);

create table MenuItems (
  id        serial primary key,
  restaurant_id integer not null,

  name      varchar(100) not null,
  type      varchar(30),  -- eg: food, drinks
  cuisine   varchar(30),  -- eg: western, eastern, japanese
  allergens text,

  foreign key(restaurant_id) references Restaurants(id) on delete cascade
);


create table Favourites(
  customer_id integer not null,
  food_id integer not null,

  foreign key(food_id) references MenuItems(id) on delete cascade,
  foreign key(customer_id) references Customers(id) on delete cascade
);


create or replace function checkRestaurantSellThisFood(mid integer, bid integer)
returns boolean as $$
declare restaurant_id_involved integer;
begin
	select id into restaurant_id_involved from restaurants where id = (select restaurant_id from branches where id = bid);
	if exists (
		select 1
		from Restaurants r inner join MenuItems m on r.id = m.restaurant_id
		where r.id = restaurant_id_involved
		and m.id = mid
	) then return true;

      Else
         Return false;
      End if;
end
$$ language PLpgSQL;


Create table Sells (
  mid integer not null,
  bid integer not null,
  price money not null,

  primary key(mid, bid),
  foreign key(mid) references MenuItems(id) on delete cascade,
  foreign key(bid) references Branches(id) on delete cascade,

  check(checkRestaurantSellThisFood(mid, bid) = true)
);

create table Timeslot (
  branch_id   integer,
  dateslot    date,
  timeslot    time,
  numSlots    integer not null,

  primary key (branch_id, dateslot, timeslot),
  foreign key (branch_id) references Branches(id) on delete cascade,
  check (numSlots > 0)
);

create or replace function checkAvailability(rDate date, rSlot time, b_id integer)
returns integer as $$
declare
  totalReserved integer;
  slots integer;
begin
	select coalesce(sum(pax), 0) into totalReserved
	from Reservations
	where reservedSlot = rSlot
	and reservedDate = rDate
  and branch_id = b_id;

	select numSlots into slots
	from Timeslot
	where branch_id = b_id
	and Timeslot.dateslot = rDate
	and Timeslot.timeslot = rSlot;
	raise notice 'slots %, total reserved %', slots, totalReserved;
	return slots - totalReserved;
end;
$$ language PLpgSQL;

create table Promotions (
  id				serial primary key,
  name				varchar(100),
  description		text,
  promo_code		varchar(50) unique,
  is_exclusive		boolean default false,
  redemption_cost	integer, -- redemption_cost only applicable when promotion is exclusive.
    
  start_date		date,
  end_date			date,
  start_timeslot	time,
  end_timeslot		time,
  check(end_date > start_date),
  check(start_timeslot < end_timeslot)
);

create table Offers (
	branch_id 	integer not null,
	promo_id	integer not null,
	
	foreign key (branch_id) references Branches on delete cascade,
	foreign key (promo_id) references Promotions on delete cascade
);


-- check if user specify a promo to use then check the following:
-- 	1) such a promotion exist
-- 	2) check whether the user owns the promo if promo is exclusive 
--  3) check if promotion is available for current branch.
--  4) check if promotion is still active. 
create or replace function ensureValidPromoUsage()
returns trigger as
$$
declare
	is_promo_exclusive boolean;
begin
	select is_exclusive into is_promo_exclusive from promotions where promo_code = new.promo_used;
	if new.promo_used isnull then
		return new;
	elseif not exists (select 1 from promotions p where new.promo_used = p.promo_code)
		or (is_promo_exclusive and
		not exists (select 1 from redemption r
			where (select promo_code from promotions where id = r.promo_id) = new.promo_used and r.customer_id = new.customer_id)) then
		raise exception 'No such promotion, %', new.promo_used;
	elsif not exists (select 1 from promotions p inner join offers o on p.id = o.promo_id 
				  where p.promo_code = new.promo_used and new.branch_id = o.branch_id) then
		raise exception 'Promotion is not available for this branch';
	elsif not (new.reservedDate >= (select start_date from promotions where promo_code = new.promo_used) and
		   new.reservedDate <= (select end_date from promotions where promo_code = new.promo_used) and
		   new.reservedSlot >= (select start_timeslot from promotions where promo_code = new.promo_used) and
		   new.reservedSlot <= (select end_timeslot from promotions where promo_code = new.promo_used)) then
		raise exception 'Promotion is currently not available';
	else
		return new;
	end if;
end
$$ language PLpgSQL;

create table Reservations (
  id        	serial primary key,
  customer_id   integer not null,
  branch_id 	integer not null,
  pax       	integer not null,
  reservedSlot  time not null,
  reservedDate  date not null,
  promo_used	varchar(50),
  confirmed		boolean default false,
  
  foreign key(promo_used) references Promotions(promo_code) on delete set null,
  foreign key(customer_id) references Customers(id) on delete cascade,
  foreign key(branch_id) references Branches(id) on delete cascade,
  foreign key(branch_id, reservedSlot, reservedDate) references Timeslot(branch_id, timeslot, dateslot),
  check (checkAvailability(reservedDate, reservedSlot, branch_id) >= pax)
);


--customer who have already did reservation for this branch cannot make another reservation of the same branch.
create or replace function customerReserveOnceInBranch()
  returns trigger as
$$
begin
  if exists (
      select 1
      from Reservations r1
      where r1.customer_id = new.customer_id
        and r1.branch_id = new.branch_id
        and r1.reservedSlot = new.reservedSlot
        and r1.reservedDate = new.reservedDate) then raise exception 'duplicate reservation detected';
  else return new;
  end if;
end;
$$
  language plpgsql;

create trigger reservation_check
  before insert or update on Reservations
  for each row
execute procedure customerReserveOnceInBranch();
-- end --

create trigger ensureValidPromoUsage
	before insert or update on Reservations
	for each row 
	execute procedure ensureValidPromoUsage();

create table Ratings(
  id serial primary key,
  rating integer not null,
  comments varchar(50),
  customer_id integer not null,
  branch_id integer not null,

  foreign key(customer_id) references Customers(id),
  foreign key(branch_id) references Branches(id),
  unique(customer_id, branch_id),
  check(rating <= 5 and rating >= 0)
);

--customer who rates the branch must have made a reservation with the branch before
create or replace function checkCustomerRateExistingBranch()
  returns trigger as
$$
begin
  if exists (
      select 1
      from Reservations r
      where new.customer_id = r.customer_id
        and new.branch_id = r.branch_id)
  then return new;
  else
    raise exception 'customer did not make reservation to this branch';
  end if;
end;
$$
  language plpgsql;

create trigger rating_check
  before insert or update on Ratings
  for each row
execute procedure checkCustomerRateExistingBranch();
-- end

create table PointTransactions (
  reservation_id 	integer unique,
  customer_id    	integer not null,
  point          	integer not null,
  description    	varchar(200) not null,
  transaction_date	timestamp default current_timestamp,

  foreign key(reservation_id) references Reservations(id),
  foreign key(customer_id) references Users(id)
);

create or replace function logPointTransactionWhenReservationConfirmed()
returns trigger as
$$
declare branch_involved varchar(100); 
begin
	if new.confirmed = true and not exists (select 1 from PointTransactions where reservation_id = new.id) then
		select b.bname into branch_involved from branches b where new.branch_id = b.id;
		insert into PointTransactions(reservation_id, customer_id, point, description) values
			(new.id, new.customer_id, 1, format('A completed reservation at %s on %s, %s', branch_involved, new.reservedDate, new.reservedSlot));
	end if;
	return new;
end
$$ language plpgsql;

create trigger logPointTransactionWhenReservationConfirmed
	after insert or update on reservations
	for each row 
	execute procedure logPointTransactionWhenReservationConfirmed();

create table Redemption (
  customer_id	integer not null,
  promo_id		integer,
  date_redeemed	timestamp default current_timestamp ,
  
  unique(customer_id, promo_id),
  foreign key(customer_id) references Customers(id) on delete cascade,
  foreign key(promo_id) references Promotions(id) on delete set null
);

create or replace function ensurePromoIdOfRedemptionNotNull()
returns trigger as 
$$
begin
	if (new.promo_id isnull) then
		raise exception 'Please specify the promotion that was redeemed';
	else
		return new;
	end if;
end
$$ language plpgsql;

create trigger ensurePromoIdOfRedemptionNotNullWhenInsert
	before insert on Redemption
	for each row 
	execute procedure ensurePromoIdOfRedemptionNotNull();

create or replace function logPointTransactionWhenRedeemed()
returns trigger as
$$
declare redemption_cost integer; promo_code varchar(50);
begin
	select p.redemption_cost into redemption_cost from promotions p where p.id = new.promo_id;
	select p.promo_code into promo_code from promotions p where p.id = new.promo_id;
	insert into PointTransactions(customer_id, point, description) values
		(new.customer_id, -1 * redemption_cost, format('Redeemed an exclusive promotion, %s', promo_code));
	return new;
end
$$ language plpgsql;

create trigger logPointTransactionWhenRedeemed
	after insert on Redemption
	for each row 
	execute procedure logPointTransactionWhenRedeemed();


