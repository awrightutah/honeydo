-- Starter seed data for HomeHub / Honeydo
-- Run after initial schema. System templates have household_id = null.

insert into public.chore_templates (title, description, room_or_category, difficulty, suggested_points, suggested_frequency, icon, is_system)
values
('Unload Dishwasher', 'Put clean dishes away neatly.', 'Kitchen', 'easy', 5, 'daily', '🍽️', true),
('Load Dishwasher', 'Load dirty dishes and start if full.', 'Kitchen', 'easy', 5, 'daily', '🧽', true),
('Wipe Kitchen Counters', 'Clear and wipe all kitchen counters.', 'Kitchen', 'easy', 5, 'daily', '✨', true),
('Take Out Trash', 'Empty trash and replace bag.', 'Kitchen', 'medium', 10, 'weekly', '🗑️', true),
('Vacuum Living Room', 'Vacuum carpet/rugs and visible floor areas.', 'Living Room', 'medium', 15, 'weekly', '🧹', true),
('Dust Living Room', 'Dust shelves, tables, and TV stand.', 'Living Room', 'easy', 10, 'weekly', '🪶', true),
('Make Bed', 'Make bed and tidy pillows/blankets.', 'Bedroom', 'easy', 5, 'daily', '🛏️', true),
('Clean Bathroom Sink', 'Wipe sink, faucet, and counter.', 'Bathroom', 'medium', 15, 'weekly', '🚰', true),
('Clean Toilet', 'Clean toilet bowl, seat, and exterior.', 'Bathroom', 'hard', 25, 'weekly', '🚽', true),
('Fold Laundry', 'Fold clean laundry and sort by person.', 'Laundry', 'medium', 15, 'weekly', '👕', true),
('Put Away Laundry', 'Put folded laundry in drawers/closet.', 'Laundry', 'medium', 15, 'weekly', '🧺', true),
('Water Plants', 'Water indoor plants as needed.', 'Household', 'easy', 5, 'weekly', '🪴', true),
('Feed Pets', 'Feed pets and refill water bowl.', 'Pets', 'easy', 5, 'daily', '🐾', true),
('Sweep Entryway', 'Sweep dirt and shoes area.', 'Entryway', 'easy', 10, 'weekly', '🧹', true),
('Mow Lawn', 'Mow yard and clean up edges if needed.', 'Yard', 'hard', 30, 'weekly', '🌱', true);

insert into public.master_recipes (title, description, ingredients, steps, prep_time_minutes, cook_time_minutes, servings, difficulty, cuisine, tags, status, average_rating, rating_count)
values
('Taco Tuesday Tacos', 'Simple family taco night starter recipe.',
 '[{"name":"ground beef","quantity":"1","unit":"lb","category":"Meat"},{"name":"taco shells","quantity":"12","unit":"count","category":"Pantry"},{"name":"shredded cheese","quantity":"2","unit":"cups","category":"Dairy"},{"name":"lettuce","quantity":"1","unit":"head","category":"Produce"},{"name":"tomato","quantity":"1","unit":"count","category":"Produce"},{"name":"taco seasoning","quantity":"1","unit":"packet","category":"Pantry"}]'::jsonb,
 '["Cook ground beef in a skillet until browned.","Drain excess fat and stir in taco seasoning according to packet instructions.","Warm taco shells.","Fill shells with beef, cheese, lettuce, and tomato."]'::jsonb,
 10, 15, 4, 'Easy', 'Mexican-inspired', '["Kid-Friendly","Quick","Weeknight"]'::jsonb, 'approved', 0, 0),
('One-Pan Lemon Chicken', 'Bright, easy chicken dinner with minimal cleanup.',
 '[{"name":"chicken breasts","quantity":"4","unit":"count","category":"Meat"},{"name":"lemon","quantity":"1","unit":"count","category":"Produce"},{"name":"olive oil","quantity":"2","unit":"tbsp","category":"Pantry"},{"name":"garlic","quantity":"3","unit":"cloves","category":"Produce"},{"name":"broccoli","quantity":"2","unit":"cups","category":"Produce"}]'::jsonb,
 '["Preheat oven to 400°F.","Place chicken and broccoli on a sheet pan.","Drizzle with olive oil, lemon juice, and garlic.","Bake until chicken reaches 165°F."]'::jsonb,
 10, 25, 4, 'Easy', 'American', '["Healthy","One-Pan","Weeknight"]'::jsonb, 'approved', 0, 0),
('Spaghetti Night', 'Classic spaghetti dinner for busy evenings.',
 '[{"name":"spaghetti","quantity":"1","unit":"lb","category":"Pantry"},{"name":"marinara sauce","quantity":"24","unit":"oz","category":"Pantry"},{"name":"ground beef","quantity":"1","unit":"lb","category":"Meat"},{"name":"parmesan cheese","quantity":"0.5","unit":"cup","category":"Dairy"}]'::jsonb,
 '["Boil pasta according to package directions.","Brown ground beef in a pan.","Add marinara sauce and simmer.","Serve sauce over pasta with parmesan."]'::jsonb,
 5, 20, 4, 'Easy', 'Italian-American', '["Comfort Food","Quick","Kid-Friendly"]'::jsonb, 'approved', 0, 0);
