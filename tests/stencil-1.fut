-- Simple rank-1 one-dimensional stencil computation.  Eventually
-- smooths out all differences.
--
-- ==
-- input { 1 [1.0, 2.0, 3.0, 4.0, 5.0, 6.0] }
-- output { [1.3333333333333333, 2.0, 3.0, 3.9999999999999996, 5.0, 5.666666666666666] }
-- input { 2 [1.0, 2.0, 3.0, 4.0, 5.0, 6.0] }
-- output {
--   [1.5555555555555554,
--    2.111111111111111,
--    2.9999999999999996,
--    3.9999999999999996,
--    4.888888888888888,
--    5.444444444444444] }


let main [n] (num_iterations: i32) (a: [n]f64): []f64 =
  loop (a) for i < num_iterations do
    map (\(i: i32): f64  ->
          let x = if i == 0 then a[i] else unsafe a[i-1]
          let y = a[i]
          let z = if i == n-1 then a[i] else unsafe a[i+1]
          let factor = 1.0/3.0 in
          factor*x + factor*y + factor*z
       ) (iota(n))
