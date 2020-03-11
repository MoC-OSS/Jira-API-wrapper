require "jira_api_wrapper/version"

module JiraApiWrapper

  ROLES =
    {'mocglobal' =>
       {
         'Account Manager' => 10161,
         'Administrators' => 10002,
         'BA' => 10104,
         'Client' => 10110,
         'Designer' => 10162,
         'Developer' => 10102,
         'Developers' => 10236,
         'Lead Developer' => 10105,
         'Project Manager' => 10101,
         'QA' => 10103,
       },
     'cosaction' =>
       {
         'Administrators' => 10002,
         'Project Manager' => 10102,
         'Developers' => 10105,
         'Developer Partner' => 10101
       },
     'romand' =>
       {
         'Administrators' => 10002,
         'Developers' => 10102,
       },
     'moctest' =>
       {
         'Administrators' => 10002,
         'Developers' => 10100,
       }
    }

  class << self

    attr_reader :instance, :authorization_type, :token, :bearer

    def configure(instance:, authorization_type: 'Basic', token: nil, bearer: nil)
      @instance = instance
      @authorization_type = authorization_type
      @token = token
      @bearer = bearer
    end

    def data(fields:, filters: nil)
      query_url = create_query_url(fields, filters)
      paged_data(query_url, fields)
    end

    def create_query_url(fields, filters)
      query_url = URI.encode("search?fields=#{fields}&jql=worklogDate >= '#{filters['from']}' AND worklogDate <= '#{filters['to']}'")
      if filters['projects'].present?
        query_url += " AND project in (#{filters['projects'].map {|el| "'#{el}'"}.join(',')})"
      end
      if filters['issue_types'].present?
        query_url += URI.encode(" AND issuetype in (#{filters['issue_types'].map {|el| "'#{el}'"}.join(',')})")
      end
      if filters['users'].present?
        query_url += URI.encode(" AND worklogAuthor in (#{filters['users'].map {|el| "'#{el}'"}.join(',')})")
      end
      if filters['statuses'].present?
        query_url += URI.encode(" AND status in (#{filters['statuses'].map {|el| "'#{el}'"}.join(',')})")
      end
      query_url
    end

    def paged_data(query_url, fields)
      issues = []

      maxResults = 100
      query_url += "&maxResults=#{maxResults}"
      issue_quantity = maxResults
      startAt = 0

      while issue_quantity == maxResults do
        response = api_request(query_url + "&startAt=#{startAt}")
        if response['issues'].present?
          issues += response['issues']
          issue_quantity = response['issues'].count
          startAt += maxResults
        else
          issue_quantity = 0
        end
      end

      if fields.include?('worklog')
        issues.each do |issue|
          if issue.dig('fields', 'worklog', 'worklogs').count == 20
            worklog_response = issue_worklogs(issue['key'])
            issue['fields']['worklog'] = worklog_response
          end
        end
      end

      issues
    end

    def base_url
      "https://#{instance}.atlassian.net/rest/api/2/"
    end

    def authorization_info
      if authorization_type == 'Bearer'
        "Bearer #{bearer[:token]}"
      else
        "Basic #{token}"
      end
    end

    def api_request(query_url)
      url = base_url + query_url
      begin
        HTTParty.get(url, {
          headers: {'Content-Type' => 'application/json', 'Authorization' => authorization_info}
        }).parsed_response
      rescue SocketError, Errno::ECONNREFUSED, Timeout::Error, HTTParty::Error, OpenSSL::SSL::SSLError  => e
        Rails.logger.info "Error: at #{Time.now} - #{e.message}"
        {}
      end
    end

    def issue_worklogs(issue_key)
      query_url = URI.encode("issue/#{issue_key}/worklog")
      api_request(query_url)
    end

    def projects(filters = {})
      query_url = 'project'
      query_url += "/#{filters['project_id']}" if filters['project_id'].present?
      response = api_request(query_url)
      if response.is_a?(Array)
        response.collect {|h| ["#{h['name']} - #{h['key']}", h['id']]}
      else
        [["#{response['name']} - #{response['key']}", response['id']]]
      end
    end

    def project_type(project_id)
      query_url = "project/#{project_id}"
      response = api_request(query_url)
      response['style']
    end

    def next_gen_project_roles(project_id)
      roles = {}
      query_url = "project/#{project_id}/role"
      response = api_request(query_url)
      response.each do |el|
        roles['Administrator'] = el[1].split('/').last if el[0] == 'Administrator'
        roles['Member'] = el[1].split('/').last if el[0] == 'Member'
      end
      roles
    end

    def user_role_actors(project_id)
      user_role_actors = []
      project_type = project_type(project_id)
      if project_type == 'next-gen'
        roles = next_gen_project_roles(project_id)
      else
        roles = ROLES[instance].select {|key, val| key != 'Client'}
      end
      roles.each do |role|
        query_url = "project/#{project_id}/role/#{role[1]}"
        response = api_request(query_url)
        if response['actors']
          users = response['actors'].collect {|h| [h['displayName'], h.dig('actorUser', 'accountId')]}.select {|k, v| v.present?}
        else
          users = []
        end
        user_role_actors << {'role' => role[0], 'actors' => users}
      end
      user_role_actors
    end

    def user_is_in_group?(account_id, group)
      query_url = "user/?accountId=#{account_id}&expand=groups"
      response = api_request(query_url)
      group = Array(group) unless group.is_a?(Array)
      (response.dig('groups', 'items')&.pluck('name') & group).present?
    end

    def user_has_role?(project_id, role)
      project_type = project_type(project_id)
      if project_type == 'next-gen'
        role_id = next_gen_project_roles(project_id)[role]
      else
        role_id = ROLES[instance][role]
      end
      if role_id.present?
        query_url = "project/#{project_id}/role/#{role_id}"
        response = api_request(query_url)
        if response['actors']
          actors = response['actors'].collect {|h| [h['displayName'], h.dig('actorUser', 'accountId')]}.select {|k, v| v.present?}
          actors.select {|key, val| val == self.bearer[:account_id]}.present?
        else
          false
        end
      else
        false
      end
    end

    def issue_types
      query_url = 'issuetype'
      response = api_request(query_url)
      response.collect {|h| [h['name']]}.uniq
    end

    def statuses
      query_url = 'status'
      response = api_request(query_url)
      response.collect {|h| [h['name'], h['id']]}
    end

    def projects_time_spent(id=nil)
      query_url = id ? "search?fields=worklog&jql=project=#{id}" : "search?fields=project,worklog"
      issues = paged_data(query_url, 'worklog')
      issues.map do |issue|
        if issue.dig('fields', 'worklog', 'worklogs')&.size == 20
          worklog_response = issue_worklog(issue['key'])
          issue['fields']['worklog'] = worklog_response
        end
      end
      if id
        issues&.map {|h| h['fields']['worklog']['worklogs']&.map {|_h| _h['timeSpentSeconds']}}&.flatten&.inject(:+).to_f
      else
        data = issues&.map {|h| {'project_jira_id' => h['fields']['project']['id'], 'seconds' => h['fields']['worklog']['worklogs']&.map {|_h| _h['timeSpentSeconds']}&.flatten&.inject(:+)}}
        group_data(data, ['project_jira_id'], summing_fields=['seconds'])
      end
    end

    def issue(key)
      query_url = "issue/#{key}"
      api_request(query_url)
    end

    def issue_worklog(issue_key)
      query_url = "issue/#{issue_key}/worklog"
      api_request(query_url)
    end

    def test
      puts 'Success!'
    end

    private

    def group_data(data, grouping_fields, summing_fields=['worklogs'])
      grouped_data = data.group_by {|hash| hash.values_at(*grouping_fields).join ":"}.values.map do |grouped|
        grouped.inject do |merged, n|
          merged.merge(n) do |key, v1, v2|
            if key.in?(grouping_fields)
              v1
            elsif key.in?(summing_fields)
              if v1.respond_to?(:to_i) && v2.respond_to?(:to_i)
                v1.to_i + v2.to_i
              else
                v1 + v2
              end
            else
              ''
            end
          end
        end
      end

      grouped_data.sort_by {|hash| hash.values_at(*grouping_fields).join ":"}
    end

  end
end
