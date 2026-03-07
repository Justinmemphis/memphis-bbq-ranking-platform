output "restaurants_table_name" {
  value = aws_dynamodb_table.restaurants.name
}

output "restaurants_table_arn" {
  value = aws_dynamodb_table.restaurants.arn
}

output "ratings_table_name" {
  value = aws_dynamodb_table.ratings.name
}

output "ratings_table_arn" {
  value = aws_dynamodb_table.ratings.arn
}

output "rating_events_table_name" {
  value = aws_dynamodb_table.rating_events.name
}

output "rating_events_table_arn" {
  value = aws_dynamodb_table.rating_events.arn
}

output "leaderboard_snapshot_table_name" {
  value = aws_dynamodb_table.leaderboard_snapshot.name
}

output "leaderboard_snapshot_table_arn" {
  value = aws_dynamodb_table.leaderboard_snapshot.arn
}
