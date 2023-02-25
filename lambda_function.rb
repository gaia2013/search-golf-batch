require "google_maps_service"
require "rakuten_web_service"
require "aws-record"

class SearchGolfApp # DynamoDBのテーブル名
include Aws::Record
integer_attr :golf_course_id, hash_key: true
integer_attr :duration1 # 基準地点１からの所要時間
integer_attr :duration2 # 基準地点２からの所要時間
end
module Area
  CODES=["8", "11", "12","13","14"]
end

module Departure
  # 基準とする出発地点（今回はこの２箇所を基準となる出発地点とする）
  DEPARTURES={
    1=>"東京駅",
    2=>"横浜駅"
  }
end

def duration_minutes(departure,destination)
  # Google Maps Platformを使って出発地点とゴルフ場の車での移動時間を出す
  gmaps=GoogleMapsService::Client.new(key:ENV["GOOGLE_MAP_API_KEY"])
  routes=gmaps.directions(
    departure,destination,region:"jp"
  )
  return unless routes.first #ルートが存在しないときはnilを返す（東京の離島など）
  duration_seconds=routes.first[:legs][0][:duration][:value] # レスポンスから所要時間を取得
  duration_seconds/60
end

def put_item(course_id, durations) #DynamoDBへ保存
  return if SearchGolfApp.find(golf_course_id:course_id) #すでにDynamoDBに同じコースIDのレコードが存在する場合保存しない
  duration=SearchGolfApp.new
  duration.golf_course_id=course_id
  duration.duration1=durations.fetch(1)
  duration.duration2=durations.fetch(2)
  duration.save
end

def lambda_handler(event:, context:)
  RakutenWebService.configure do |c|
    c.application_id=ENV["RAKUTEN_APPID"]
    c.affiliate_id=ENV["RAKUTEN_AFID"]
  end

  Area::CODES.each do |code| #すべてのエリアに対して以下操作を行う
    #1.このエリアのゴルフ場を楽天APIですべて取得する
    1.upto(100) do |page|
      # コース一覧を取得する(rakutenAPIの使用上、一度にすべてのゴルフ場を取得できないのでpage分けて取得.
      # 参考(楽天APIの仕様):https://webservice.rakuten.co.jp/api/goragolfcoursesearch/
      courses=RakutenWebService::Gora::Course.search(areaCode:code, page:page)
      courses.each do |course|
        course_id=course["golfCourseId"]
        course_name=course["golfCourseName"]
        next if course_name.include?("レッスン") #ゴルフ場以外の情報（レッスン情報）をスキップ

        #2.出発地点から取得したゴルフ場までの所要時間をGoogleMapsPlatformdで取得する
        durations={}
        Departure::DEPARTURES.each do |duration_id, departure|
          minutes=duration_minutes(departure, course_name)
          durations.store(duration_id, minutes) if minutes
        end
        #3.取得した情報をDynamoDBに保存する
        put_item(course_id,durations) unless durations.empty? # コースIDとそれぞれの出発地点とコースの移動時間をDynamoDBへ格納する
      end
      break unless courses.next_page? # 次のページが存在するかを確認するメソッド
    end
  end
  {statusCode: 200}
end
