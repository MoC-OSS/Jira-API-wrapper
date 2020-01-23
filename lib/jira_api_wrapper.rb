require "jira_api_wrapper/version"

module JiraApiWrapper
  # extend ::Helper

  class << self

    ROLES =
      {'mocglobal.atlassian.net' =>
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
       'romand.atlassian.net' =>
         {
           'Administrators' => 10002,
           'Developers' => 10102,
         },
       'moctest.atlassian.net' =>
         {
           'Administrators' => 10002,
           'Developers' => 10100,
         },
       'cosaction.atlassian.net' =>
         {
           'Administrators' => 10002,
           'Project Manager' => 10102,
           'Developers' => 10105,
           'Developer Partner' => 10101
         }
      }

    attr_reader :api_base_url, :api_url, :current_jwt_user, :authorization_type

    def configure(api_base_url, current_jwt_user: nil, authorization_type: 'Bearer')
      @api_base_url = api_base_url
      @api_url = api_base_url + '/rest/api/2/'
      @current_jwt_user = current_jwt_user
      @authorization_type = authorization_type
    end

    def projects(opts = {})
      query_url = 'project'
      query_url += "/#{opts['project_id']}" if opts['project_id'].present?
      response = api_request(query_url)
      response = response.parsed_response
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
        roles = ROLES[api_base_url.gsub('https://', '')].select {|key, val| key != 'Client'}
      end
      roles.each do |role|
        query_url = "project/#{project_id}/role/#{role[1]}"
        response = api_request(query_url)
        if response.parsed_response['actors']
          users = response.parsed_response['actors'].collect {|h| [h['displayName'], h.dig('actorUser', 'accountId')]}.select {|k, v| v.present?}
        else
          users = []
        end
        user_role_actors << {'role' => role[0], 'actors' => users}
      end
      user_role_actors
    end

    def user_is_in_group?(account_id, group)
      query_url = "user/?accountId=#{account_id}&expand=groups"
      response = api_request(query_url).parsed_response
      group = Array(group) unless group.is_a?(Array)
      (response.dig('groups', 'items')&.pluck('name') & group).present?
    end

    def user_has_role?(project_id, role)
      project_type = project_type(project_id)
      if project_type == 'next-gen'
        role_id = next_gen_project_roles(project_id)[role]
      else
        role_id = ROLES[api_base_url.gsub('https://', '')][role]
      end
      if role_id.present?
        query_url = "project/#{project_id}/role/#{role_id}"
        response = api_request(query_url)
        if response.parsed_response['actors']
          actors = response.parsed_response['actors'].collect {|h| [h['displayName'], h.dig('actorUser', 'accountId')]}.select {|k, v| v.present?}
          actors.select {|key, val| val == current_jwt_user.account_id}.present?
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
      response.parsed_response.collect {|h| [h['name']]}.uniq
    end

    def statuses
      query_url = 'status'
      response = api_request(query_url)
      response.parsed_response.collect {|h| [h['name'], h['id']]}
    end

    def projects_time_spent(id=nil)
      query_url = id ? "search?fields=worklog&jql=project=#{id}" : "search?fields=project,worklog"
      issues = paged_data(query_url)
      issues.map do |issue|
        if issue.dig('fields', 'worklog', 'worklogs').count == 20
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
      response = api_request(query_url)
      response.parsed_response
    end

    def paged_data(query_url)
      maxResults = 100
      query_url += "&maxResults=#{maxResults}"
      issue_quantity = maxResults
      startAt = 0
      issues = []
      while issue_quantity == maxResults do
        response = api_request(query_url+"&startAt=#{startAt}").parsed_response
        if response['issues'].present?
          issues += response['issues']
          issue_quantity = response['issues'].count
        else
          issue_quantity = 0
        end
        startAt += maxResults
      end
      issues
    end

    def data(opts)
      query_url = create_url(opts)
      paged_data(query_url)
    end

    def create_url(opts)
      query_url = URI.encode("search?fields=project,summary,issuetype,status,comment,customfield_10008,parent,components,worklog&jql=worklogDate >= #{opts['from']} AND worklogDate <= #{opts['to']}")
      if opts.key?('projects')
        query_url += " AND project in (#{opts['projects'].map {|el| "'#{el}'"}.join(',')})"
      end
      if opts.key?('issue_types')
        query_url += URI.encode(" AND issuetype in (#{opts['issue_types'].map {|el| "'#{el}'"}.join(',')})")
      end
      if opts.key?('users')
        query_url += URI.encode(" AND worklogAuthor in (#{opts['users'].map {|el| "'#{el}'"}.join(',')})")
      end
      if opts.key?('statuses')
        query_url += URI.encode(" AND status in (#{opts['statuses'].map {|el| "'#{el}'"}.join(',')})")
      end
      query_url
    end

    def api_request(query_url)
      url = api_url + query_url
      if authorization_type == 'Bearer'
        HTTParty.get(url, {
          headers: {'Content-Type' => 'application/json', 'Authorization' => "Bearer " + current_jwt_user.oauth_access_token}
        })
      else
        HTTParty.get(url, {
          headers: {'Content-Type' => 'application/json', 'Authorization' => "Basic Ym9nZGFuLnNlcmdpaWVua29AbWFzdGVyb2Zjb2RlLmNvbTpnRlBJZmxoZXp0ZlZEc2dMWlFhYTU1OUM="}
        })
      end
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
