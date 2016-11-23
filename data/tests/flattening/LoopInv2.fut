-- ==
-- input {
--   [ [ [1,2,3], [4,5,6] ]
--   , [ [6,7,8], [9,10,11] ]
--   , [ [3,2,1], [4,5,6] ]
--   , [ [8,7,6], [11,10,9] ]
--   ]
--   [1,2,3]
-- }
-- output {
--   [[[2, 4, 6],
--     [5, 7, 9]],
--    [[7, 9, 11],
--     [10, 12, 14]],
--    [[4, 4, 4],
--     [5, 7, 9]],
--    [[9, 9, 9],
--     [12, 12, 12]]]
-- }
fun addRows (xs: []int, ys: []int): []int =
  map (+) xs ys

fun main (xsss: [][][]int, ys: []int): [][][]int =
  map  (fn (xss: [][]int): [][]int  =>
         map (fn (xs: []int): []int  => addRows(xs,ys)) xss
      ) xsss
