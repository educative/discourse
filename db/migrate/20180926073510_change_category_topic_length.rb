class ChangeCategoryTopicLength < ActiveRecord::Migration[5.2]
  def up
    change_column :categories, :name, :string, :limit => 255
    change_column :categories, :name_lower, :string, :limit => 255
    change_column :topics, :title, :string, :limit => 255
  end

  def down
    change_column :categories, :name, :string, :limit => 50
    change_column :categories, :name_lower, :string, :limit => 50
    change_column :topics, :title, :string, :limit => 50
  end
end
